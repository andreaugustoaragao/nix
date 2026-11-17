//! Carry lan-mouse's datagrams across one QUIC connection.
//!
//! lan-mouse addresses every event to the other machine, and each direction is
//! its own UDP packet. The workstation cannot address the VM, so the return
//! path dies at the Parallels NAT. Both copies of lan-mouse bind to loopback
//! instead, and this process splices those two sockets together.
//!
//! The VM dials. The workstation listens. Datagrams flow both ways on the one
//! connection, so crossing the screen edge works in both directions and the Mac
//! never accepts an inbound connection.
//!
//! While the cursor is away, the VM's lan-mouse has released the pointer and
//! no longer sees the keyboard. The VM side of the bridge watches the evdev
//! device that owns it and, on the release key, sends the same `Leave` event
//! lan-mouse uses to hand the pointer back.

use quinn::{
    ClientConfig, Connection, Endpoint, EndpointConfig, IdleTimeout, ServerConfig, TokioRuntime,
    TransportConfig, VarInt,
};
use rcgen::CertificateParams;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use socket2::{Domain, SockAddr, Socket, Type};
use std::error::Error;
use std::fs::File;
use std::io::Read;
use std::net::{Ipv4Addr, SocketAddr, UdpSocket};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const EVENT_SIZE: usize = 21;
const LEAVE: u8 = 10;
const RELEASE_CODE: u16 = 70; // KEY_SCROLLLOCK
const KEY_EVENT: u16 = 1;
const KEY_RELEASE: i32 = 0;

#[derive(Clone, Copy)]
enum Role {
    Listen,
    Dial,
}

struct Args {
    role: Role,
    peer: SocketAddr,
    local: SocketAddr,
    cert: PathBuf,
    key: PathBuf,
    input: Option<PathBuf>,
}

fn main() {
    if let Err(err) = run() {
        eprintln!("cursor-bridge: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error + Send + Sync>> {
    let args = parse(std::env::args().skip(1))?;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    runtime.block_on(serve(args))
}

async fn serve(args: Args) -> Result<(), Box<dyn Error + Send + Sync>> {
    let socket = bind(&args.local)?;
    loop {
        let result = match args.role {
            Role::Listen => accept(&args, socket.try_clone()?).await,
            Role::Dial => connect(&args, socket.try_clone()?).await,
        };
        if let Err(err) = result {
            eprintln!("cursor-bridge: {err}; reconnecting");
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
}

async fn accept(args: &Args, socket: UdpSocket) -> Result<(), Box<dyn Error + Send + Sync>> {
    let endpoint = Endpoint::new(
        EndpointConfig::default(),
        Some(server_config(&args.cert, &args.key)?),
        socket.try_clone()?.into(),
        Arc::new(TokioRuntime),
    )?;
    let incoming = endpoint.accept().await.ok_or("listener closed")?;
    let connection = incoming.await?;
    splice(connection, socket).await
}

async fn connect(args: &Args, socket: UdpSocket) -> Result<(), Box<dyn Error + Send + Sync>> {
    let mut endpoint = Endpoint::client(args.local)?;
    endpoint.set_default_client_config(client_config(&args.cert)?);
    let connection = endpoint.connect(args.peer, "cursor-bridge")?.await?;
    let release = release_task(args.input.clone(), connection.clone());
    tokio::pin!(release);
    tokio::select! {
        result = splice(connection, socket) => result,
        result = &mut release => result,
    }
}

async fn splice(
    connection: Connection,
    socket: UdpSocket,
) -> Result<(), Box<dyn Error + Send + Sync>> {
    let socket = Arc::new(socket);
    let peer = Arc::new(std::sync::Mutex::new(None));
    let outbound = outbound(connection.clone(), socket.clone(), peer.clone());
    let inbound = inbound(connection, socket, peer);
    tokio::pin!(outbound, inbound);
    tokio::select! {
        result = &mut outbound => result,
        result = &mut inbound => result,
    }
}

async fn outbound(
    connection: Connection,
    socket: Arc<UdpSocket>,
    peer: Arc<std::sync::Mutex<Option<SocketAddr>>>,
) -> Result<(), Box<dyn Error + Send + Sync>> {
    let mut buffer = [0u8; 2048];
    let socket = tokio::net::UdpSocket::from_std(socket.try_clone()?)?;
    loop {
        let (length, from) = socket.recv_from(&mut buffer).await?;
        if length > EVENT_SIZE {
            continue;
        }
        *peer.lock().unwrap() = Some(from);
        let mut stream = connection.open_uni().await?;
        stream.write_all(&[length as u8]).await?;
        stream.write_all(&buffer[..length]).await?;
        stream.finish()?;
    }
}

async fn inbound(
    connection: Connection,
    socket: Arc<UdpSocket>,
    peer: Arc<std::sync::Mutex<Option<SocketAddr>>>,
) -> Result<(), Box<dyn Error + Send + Sync>> {
    loop {
        let mut stream = connection.accept_uni().await?;
        let mut length = [0u8; 1];
        stream.read_exact(&mut length).await?;
        let length = length[0] as usize;
        if length == 0 || length > EVENT_SIZE {
            continue;
        }
        let mut buffer = [0u8; EVENT_SIZE];
        stream.read_exact(&mut buffer[..length]).await?;
        let Some(destination) = *peer.lock().unwrap() else {
            continue;
        };
        socket.send_to(&buffer[..length], destination)?;
    }
}

async fn release_task(
    device: Option<PathBuf>,
    connection: Connection,
) -> Result<(), Box<dyn Error + Send + Sync>> {
    let Some(device) = device else {
        return std::future::pending().await;
    };
    let mut input = File::open(device)?;
    let mut event = [0u8; 24];
    let mut leave = [0u8; EVENT_SIZE];
    leave[0] = LEAVE;
    loop {
        input.read_exact(&mut event)?;
        let kind = u16::from_ne_bytes([event[16], event[17]]);
        let code = u16::from_ne_bytes([event[18], event[19]]);
        let value = i32::from_ne_bytes(event[20..24].try_into()?);
        if kind == KEY_EVENT && code == RELEASE_CODE && value == KEY_RELEASE {
            let mut stream = connection.open_uni().await?;
            stream.write_all(&leave).await?;
            stream.finish()?;
        }
    }
}

fn server_config(
    cert: &PathBuf,
    key: &PathBuf,
) -> Result<ServerConfig, Box<dyn Error + Send + Sync>> {
    let certificate = read_cert(cert)?;
    let key = PrivateKeyDer::Pkcs8(read_key(key)?);
    let mut config = ServerConfig::with_single_cert(vec![certificate], key)?;
    config.transport_config(transport());
    Ok(config)
}

fn client_config(cert: &PathBuf) -> Result<ClientConfig, Box<dyn Error + Send + Sync>> {
    let certificate = read_cert(cert)?;
    let verifier = Arc::new(Verifier(certificate));
    let mut config = ClientConfig::new(Arc::new(
        quinn::crypto::rustls::QuicClientConfig::try_from(
            rustls::ClientConfig::builder()
                .dangerous()
                .with_custom_certificate_verifier(verifier)
                .with_no_client_auth(),
        )?,
    ));
    config.transport_config(transport());
    Ok(config)
}

fn transport() -> Arc<TransportConfig> {
    let mut transport = TransportConfig::default();
    transport.max_concurrent_uni_streams(VarInt::from_u32(1024));
    transport.keep_alive_interval(Some(Duration::from_secs(5)));
    transport.max_idle_timeout(Some(IdleTimeout::try_from(Duration::from_secs(20)).unwrap()));
    Arc::new(transport)
}

#[derive(Debug)]
struct Verifier(CertificateDer<'static>);

impl rustls::client::danger::ServerCertVerifier for Verifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        if end_entity == &self.0 {
            Ok(rustls::client::danger::ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General("unexpected cursor-bridge certificate".into()))
        }
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::PeerIncompatible(
            rustls::PeerIncompatible::Tls12NotOffered,
        ))
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

fn read_cert(path: &PathBuf) -> Result<CertificateDer<'static>, Box<dyn Error + Send + Sync>> {
    let mut reader = std::io::BufReader::new(File::open(path)?);
    rustls_pemfile::certs(&mut reader)
        .next()
        .ok_or("certificate file is empty")?
        .map_err(Into::into)
}

fn read_key(path: &PathBuf) -> Result<PrivatePkcs8KeyDer<'static>, Box<dyn Error + Send + Sync>> {
    let mut reader = std::io::BufReader::new(File::open(path)?);
    match rustls_pemfile::private_key(&mut reader)?.ok_or("key file is empty")? {
        PrivateKeyDer::Pkcs8(key) => Ok(key),
        _ => Err("cursor-bridge key must be PKCS#8".into()),
    }
}

fn bind(address: &SocketAddr) -> Result<UdpSocket, Box<dyn Error + Send + Sync>> {
    let socket = Socket::new(Domain::IPV4, Type::DGRAM, None)?;
    socket.set_reuse_address(true)?;
    socket.bind(&SockAddr::from(*address))?;
    socket.set_nonblocking(true)?;
    Ok(socket.into())
}

fn parse(mut args: impl Iterator<Item = String>) -> Result<Args, Box<dyn Error + Send + Sync>> {
    let mut role = None;
    let mut peer = None;
    let mut local = None;
    let mut cert = None;
    let mut key = None;
    let mut input = None;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--listen" => role = Some(Role::Listen),
            "--dial" => role = Some(Role::Dial),
            "--peer" => peer = Some(take(&mut args, "--peer")?.parse()?),
            "--local" => local = Some(take(&mut args, "--local")?.parse()?),
            "--cert" => cert = Some(PathBuf::from(take(&mut args, "--cert")?)),
            "--key" => key = Some(PathBuf::from(take(&mut args, "--key")?)),
            "--input" => input = Some(PathBuf::from(take(&mut args, "--input")?)),
            other => return Err(format!("unknown argument {other}").into()),
        }
    }
    Ok(Args {
        role: role.ok_or("missing --listen or --dial")?,
        peer: peer.ok_or("missing --peer")?,
        local: local.ok_or("missing --local")?,
        cert: cert.ok_or("missing --cert")?,
        key: key.ok_or("missing --key")?,
        input,
    })
}

fn take(
    args: &mut impl Iterator<Item = String>,
    flag: &str,
) -> Result<String, Box<dyn Error + Send + Sync>> {
    args.next().ok_or(format!("missing value for {flag}").into())
}

#[allow(dead_code)]
fn issue() -> Result<(String, String), Box<dyn Error + Send + Sync>> {
    let key = rcgen::KeyPair::generate()?;
    let certificate = CertificateParams::new(vec!["cursor-bridge".to_string()])?.self_signed(&key)?;
    Ok((certificate.pem(), key.serialize_pem()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn pair() -> (CertificateDer<'static>, PrivatePkcs8KeyDer<'static>) {
        let key = rcgen::KeyPair::generate().unwrap();
        let certificate =
            CertificateParams::new(vec!["cursor-bridge".to_string()]).unwrap().self_signed(&key).unwrap();
        let der = key.serialize_der();
        (certificate.der().clone(), der.into())
    }

    fn memory_socket() -> (UdpSocket, SocketAddr) {
        let socket = bind(&SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
        let address = socket.local_addr().unwrap();
        (socket, address)
    }

    fn blocking_socket() -> (UdpSocket, SocketAddr) {
        let socket = UdpSocket::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
        socket.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let address = socket.local_addr().unwrap();
        (socket, address)
    }

    #[test]
    fn leave_event_matches_lan_mouse() {
        let mut leave = [0u8; EVENT_SIZE];
        leave[0] = LEAVE;
        assert_eq!(leave.len(), 21);
        assert_eq!(leave[0], 10);
    }

    #[test]
    fn certificate_round_trips() {
        let (cert, key) = issue().unwrap();
        let dir = std::env::temp_dir().join(format!("cursor-bridge-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let cert_path = dir.join("cert.pem");
        let key_path = dir.join("key.pem");
        std::fs::write(&cert_path, cert).unwrap();
        std::fs::write(&key_path, key).unwrap();
        assert!(read_cert(&cert_path).is_ok());
        assert!(read_key(&key_path).is_ok());
        std::fs::remove_dir_all(dir).ok();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn datagrams_cross_both_ways_from_one_address() {
        let (certificate, key) = pair();
        let mut server = ServerConfig::with_single_cert(vec![certificate.clone()], key.into()).unwrap();
        server.transport_config(transport());
        let (listener, listen_addr) = memory_socket();
        let endpoint = Endpoint::new(
            EndpointConfig::default(),
            Some(server),
            listener.into(),
            Arc::new(TokioRuntime),
        )
        .unwrap();

        let mut client = Endpoint::client(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).unwrap();
        let verifier = Arc::new(Verifier(certificate));
        let mut config = ClientConfig::new(Arc::new(
            quinn::crypto::rustls::QuicClientConfig::try_from(
                rustls::ClientConfig::builder()
                    .dangerous()
                    .with_custom_certificate_verifier(verifier)
                    .with_no_client_auth(),
            )
            .unwrap(),
        ));
        config.transport_config(transport());
        client.set_default_client_config(config);

        let (workstation, _) = blocking_socket();
        let (vm, _) = blocking_socket();
        let accepted = tokio::spawn(async move { endpoint.accept().await.unwrap().await.unwrap() });
        let connection = client.connect(listen_addr, "cursor-bridge").unwrap().await.unwrap();
        let accepted = accepted.await.unwrap();

        let (server_lan, server_lan_addr) = memory_socket();
        let (client_lan, client_lan_addr) = memory_socket();
        let server_side = tokio::spawn(splice(accepted, server_lan));
        let client_side = tokio::spawn(splice(connection, client_lan));

        vm.send_to(b"ready", client_lan_addr).unwrap();
        workstation.send_to(b"ready", server_lan_addr).unwrap();
        let mut buffer = [0u8; 16];
        let (length, _) = workstation.recv_from(&mut buffer).unwrap();
        assert_eq!(&buffer[..length], b"ready");
        let (length, _) = vm.recv_from(&mut buffer).unwrap();
        assert_eq!(&buffer[..length], b"ready");

        workstation.send_to(b"out", server_lan_addr).unwrap();
        let (length, from) = vm.recv_from(&mut buffer).unwrap();
        assert_eq!(&buffer[..length], b"out");

        vm.send_to(b"back", from).unwrap();
        let (length, from) = workstation.recv_from(&mut buffer).unwrap();
        assert_eq!(&buffer[..length], b"back");
        assert_eq!(from, server_lan_addr);

        server_side.abort();
        client_side.abort();
    }
}
