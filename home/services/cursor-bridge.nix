{
  config,
  pkgs,
  lib,
  hostName,
  osConfig,
  unstable-pkgs,
  ...
}:

# One keyboard and mouse between prl-dev-vm and the workstation. The VM owns
# the devices. Both machines run lan-mouse against loopback, and cursor-bridge
# carries its datagrams both ways over the single QUIC connection the VM
# opens. The workstation cannot address the VM, so nothing listens there.
let
  bridge = pkgs.callPackage ../../pkgs/cursor-bridge.nix { };
  lanMouse = pkgs.lan-mouse.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.python3 ];
    postPatch = (old.postPatch or "") + ''
      # P1-1: Force both UDP binds in lan-mouse 0.10.0 onto 127.0.0.1.
      substituteInPlace src/server/network_task.rs \
        --replace-fail 'SocketAddr::new("0.0.0.0".parse().unwrap(),' 'SocketAddr::new("127.0.0.1".parse().unwrap(),'
      test "$(grep -Fc 'SocketAddr::new("127.0.0.1".parse().unwrap(),' src/server/network_task.rs)" -eq 2
      ! grep -Fq '0.0.0.0' src/server/network_task.rs

      # V7-3: Bind WlrootsEmulation via verified listener (st_dev, st_ino),
      # SO_PEERCRED + /proc/<pid>/stat starttime, and blocking Connection::from_socket.
      python3 - <<'PY'
      from pathlib import Path

      wlroots_path = Path("input-emulation/src/wlroots.rs")
      wlroots = wlroots_path.read_text()

      old_imports = """use std::collections::HashMap;
      use std::io;
      use std::os::fd::{AsFd, OwnedFd};"""
      new_imports = """use std::collections::HashMap;
      use std::io;
      use std::os::fd::{AsFd, OwnedFd};
      use std::os::unix::fs::{FileTypeExt, MetadataExt};
      use std::os::unix::net::UnixStream as StdUnixStream;
      use std::path::PathBuf;"""
      assert old_imports in wlroots, "wlroots imports anchor missing"
      wlroots = wlroots.replace(old_imports, new_imports, 1)

      old_struct = """pub(crate) struct WlrootsEmulation {
          last_flush_failed: bool,
          state: State,
          queue: EventQueue<State>,
      }"""
      new_struct = """pub(crate) struct WlrootsEmulation {
          last_flush_failed: bool,
          bound_lifetime_id: String,
          state: State,
          queue: EventQueue<State>,
      }

      fn current_euid() -> io::Result<u32> {
          let status = std::fs::read_to_string("/proc/self/status")?;
          for line in status.lines() {
              if let Some(rest) = line.strip_prefix("Uid:") {
                  let mut cols = rest.split_whitespace();
                  let _real = cols.next();
                  if let Some(euid) = cols.next() {
                      return euid
                          .parse::<u32>()
                          .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e));
                  }
              }
          }
          Err(io::Error::new(io::ErrorKind::NotFound, "Uid line missing in /proc/self/status"))
      }

      fn read_proc_starttime(pid: i32) -> io::Result<u64> {
          let stat = std::fs::read_to_string(format!("/proc/{pid}/stat"))?;
          let rparen = stat
              .rfind(')')
              .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "malformed /proc/pid/stat"))?;
          let after = &stat[rparen + 1..];
          let field22 = after
              .split_whitespace()
              .nth(19)
              .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing starttime field"))?;
          field22
              .parse::<u64>()
              .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
      }

      fn connect_verified_wayland() -> Result<(Connection, String), WlrootsEmulationCreationError> {
          if std::env::var_os("WAYLAND_SOCKET").is_some() {
              return Err(io::Error::new(
                  io::ErrorKind::PermissionDenied,
                  "WAYLAND_SOCKET fd inheritance is refused for seat identity verification",
              )
              .into());
          }
          let display = std::env::var_os("WAYLAND_DISPLAY")
              .filter(|v| !v.is_empty())
              .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "WAYLAND_DISPLAY unset"))?;
          let display_path = PathBuf::from(&display);
          let socket_path = if display_path.is_absolute() {
              display_path
          } else {
              let runtime_dir = std::env::var_os("XDG_RUNTIME_DIR")
                  .filter(|v| !v.is_empty())
                  .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "XDG_RUNTIME_DIR unset"))?;
              PathBuf::from(runtime_dir).join(display_path)
          };

          let pre_meta = std::fs::metadata(&socket_path)?;
          if !pre_meta.file_type().is_socket() {
              return Err(io::Error::new(io::ErrorKind::InvalidInput, "WAYLAND_DISPLAY is not a socket").into());
          }
          let pre_dev = pre_meta.dev();
          let pre_ino = pre_meta.ino();

          let std_stream = StdUnixStream::connect(&socket_path)?;
          let post_meta = std::fs::metadata(&socket_path)?;
          if !post_meta.file_type().is_socket() || post_meta.dev() != pre_dev || post_meta.ino() != pre_ino {
              return Err(io::Error::new(
                  io::ErrorKind::PermissionDenied,
                  "Wayland listener inode changed during connect",
              )
              .into());
          }

          std_stream.set_nonblocking(true)?;
          let tokio_stream = tokio::net::UnixStream::from_std(std_stream)?;
          let cred = tokio_stream.peer_cred()?;
          let euid = current_euid()?;
          if cred.uid() != euid {
              return Err(io::Error::new(
                  io::ErrorKind::PermissionDenied,
                  "Wayland compositor peer uid mismatch",
              )
              .into());
          }
          let pid = cred
              .pid()
              .filter(|&p| p > 0)
              .ok_or_else(|| io::Error::new(io::ErrorKind::PermissionDenied, "missing peer pid"))?;
          let starttime = read_proc_starttime(pid)?;

          let std_stream = tokio_stream.into_std()?;
          std_stream.set_nonblocking(false)?;
          let conn = Connection::from_socket(std_stream)?;
          let lifetime_id = format!("{}:{pid}:{starttime}:{pre_dev}:{pre_ino}", cred.uid());
          Ok((conn, lifetime_id))
      }"""
      assert old_struct in wlroots, "wlroots struct anchor missing"
      wlroots = wlroots.replace(old_struct, new_struct, 1)

      old_new = """    pub(crate) fn new() -> Result<Self, WlrootsEmulationCreationError> {
              let conn = Connection::connect_to_env()?;"""
      new_new = """    pub(crate) fn new() -> Result<Self, WlrootsEmulationCreationError> {
              let (conn, bound_lifetime_id) = connect_verified_wayland()?;"""
      assert old_new in wlroots, "wlroots new anchor missing"
      wlroots = wlroots.replace(old_new, new_new, 1)

      old_init = """        let mut emulate = WlrootsEmulation {
                  last_flush_failed: false,"""
      new_init = """        let mut emulate = WlrootsEmulation {
                  last_flush_failed: false,
                  bound_lifetime_id,"""
      assert old_init in wlroots, "wlroots init anchor missing"
      wlroots = wlroots.replace(old_init, new_init, 1)

      old_trait = """    async fn terminate(&mut self) {
              /* nothing to do */
          }
      }"""
      new_trait = """    async fn terminate(&mut self) {
              /* nothing to do */
          }

          fn bound_compositor_lifetime_id(&self) -> Option<&str> {
              Some(&self.bound_lifetime_id)
          }

          fn can_accept_and_flush(&mut self) -> Result<bool, EmulationError> {
              if self.last_flush_failed {
                  match self.queue.flush() {
                      Ok(()) => {
                          self.last_flush_failed = false;
                          Ok(true)
                      }
                      Err(WaylandError::Io(e)) if e.kind() == io::ErrorKind::WouldBlock => Ok(false),
                      Err(e) => Err(e.into()),
                  }
              } else {
                  Ok(true)
              }
          }

          fn is_flushed(&mut self) -> Result<bool, EmulationError> {
              match self.queue.flush() {
                  Ok(()) => {
                      self.last_flush_failed = false;
                      Ok(true)
                  }
                  Err(WaylandError::Io(e)) if e.kind() == io::ErrorKind::WouldBlock => {
                      self.last_flush_failed = true;
                      Ok(false)
                  }
                  Err(e) => Err(e.into()),
              }
          }
      }"""
      assert old_trait in wlroots, "wlroots trait anchor missing"
      wlroots = wlroots.replace(old_trait, new_trait, 1)
      wlroots_path.write_text(wlroots)

      # V4-1, V5-2, V6-2, V7-1, V7-3: In-place retained-obligation InputEmulation.
      lib_path = Path("input-emulation/src/lib.rs")
      lib_rs = lib_path.read_text()

      old_lib_imports = """use std::{
          collections::{HashMap, HashSet},
          fmt::Display,
      };

      use input_event::{Event, KeyboardEvent};"""
      new_lib_imports = """use std::{
          collections::{BTreeSet, HashMap, HashSet},
          fmt::Display,
          time::Duration,
      };

      use input_event::{Event, KeyboardEvent, PointerEvent};"""
      assert old_lib_imports in lib_rs, "lib imports anchor missing"
      lib_rs = lib_rs.replace(old_lib_imports, new_lib_imports, 1)

      old_lib_struct = """pub struct InputEmulation {
          emulation: Box<dyn Emulation>,
          handles: HashSet<EmulationHandle>,
          pressed_keys: HashMap<EmulationHandle, HashSet<u32>>,
      }"""
      new_lib_struct = """pub struct InputEmulation {
          emulation: Box<dyn Emulation>,
          handles: HashSet<EmulationHandle>,
          pressed_keys: HashMap<EmulationHandle, BTreeSet<u32>>,
          pressed_buttons: HashMap<EmulationHandle, BTreeSet<u32>>,
          dirty_modifiers: HashSet<EmulationHandle>,
          pending_release: HashSet<EmulationHandle>,
          retiring_handles: HashSet<EmulationHandle>,
          recreated_while_retiring: HashSet<EmulationHandle>,
          pub backend_failed: bool,
      }"""
      assert old_lib_struct in lib_rs, "lib struct anchor missing"
      lib_rs = lib_rs.replace(old_lib_struct, new_lib_struct, 1)

      old_lib_ctor = """        Ok(Self {
                  emulation,
                  handles: HashSet::new(),
                  pressed_keys: HashMap::new(),
              })"""
      new_lib_ctor = """        Ok(Self {
                  emulation,
                  handles: HashSet::new(),
                  pressed_keys: HashMap::new(),
                  pressed_buttons: HashMap::new(),
                  dirty_modifiers: HashSet::new(),
                  pending_release: HashSet::new(),
                  retiring_handles: HashSet::new(),
                  recreated_while_retiring: HashSet::new(),
                  backend_failed: false,
              })"""
      assert old_lib_ctor in lib_rs, "lib ctor anchor missing"
      lib_rs = lib_rs.replace(old_lib_ctor, new_lib_ctor, 1)

      old_lib_methods = """    pub async fn consume(
              &mut self,
              event: Event,
              handle: EmulationHandle,
          ) -> Result<(), EmulationError> {
              match event {
                  Event::Keyboard(KeyboardEvent::Key { key, state, .. }) => {
                      // prevent double pressed / released keys
                      if self.update_pressed_keys(handle, key, state) {
                          self.emulation.consume(event, handle).await?;
                      }
                      Ok(())
                  }
                  _ => self.emulation.consume(event, handle).await,
              }
          }

          pub async fn create(&mut self, handle: EmulationHandle) -> bool {
              if self.handles.insert(handle) {
                  self.pressed_keys.insert(handle, HashSet::new());
                  self.emulation.create(handle).await;
                  true
              } else {
                  false
              }
          }

          pub async fn destroy(&mut self, handle: EmulationHandle) {
              let _ = self.release_keys(handle).await;
              if self.handles.remove(&handle) {
                  self.pressed_keys.remove(&handle);
                  self.emulation.destroy(handle).await
              }
          }

          pub async fn terminate(&mut self) {
              for handle in self.handles.iter().cloned().collect::<Vec<_>>() {
                  self.destroy(handle).await
              }
              self.emulation.terminate().await
          }

          pub async fn release_keys(&mut self, handle: EmulationHandle) -> Result<(), EmulationError> {
              if let Some(keys) = self.pressed_keys.get_mut(&handle) {
                  let keys = keys.drain().collect::<Vec<_>>();
                  for key in keys {
                      let event = Event::Keyboard(KeyboardEvent::Key {
                          time: 0,
                          key,
                          state: 0,
                      });
                      self.emulation.consume(event, handle).await?;
                      if let Ok(key) = input_event::scancode::Linux::try_from(key) {
                          log::warn!("releasing stuck key: {key:?}");
                      }
                  }
              }

              let event = Event::Keyboard(KeyboardEvent::Modifiers {
                  depressed: 0,
                  latched: 0,
                  locked: 0,
                  group: 0,
              });
              self.emulation.consume(event, handle).await?;
              Ok(())
          }

          pub fn has_pressed_keys(&self, handle: EmulationHandle) -> bool {
              self.pressed_keys
                  .get(&handle)
                  .is_some_and(|p| !p.is_empty())
          }

          /// update the pressed_keys for the given handle
          /// returns whether the event should be processed
          fn update_pressed_keys(&mut self, handle: EmulationHandle, key: u32, state: u8) -> bool {
              let Some(pressed_keys) = self.pressed_keys.get_mut(&handle) else {
                  return false;
              };

              if state == 0 {
                  // currently pressed => can release
                  pressed_keys.remove(&key)
              } else {
                  // currently not pressed => can press
                  pressed_keys.insert(key)
              }
          }"""

      new_lib_methods = """    pub fn bound_compositor_lifetime_id(&self) -> Option<&str> {
              self.emulation.bound_compositor_lifetime_id()
          }

          pub fn is_flushed(&mut self) -> Result<bool, EmulationError> {
              self.emulation.is_flushed()
          }

          pub fn handle_has_held_state(&self, handle: EmulationHandle) -> bool {
              self.pressed_keys.get(&handle).is_some_and(|p| !p.is_empty())
                  || self.pressed_buttons.get(&handle).is_some_and(|b| !b.is_empty())
                  || self.dirty_modifiers.contains(&handle)
          }

          pub fn has_unflushed_obligations(&self) -> bool {
              !self.pending_release.is_empty() || !self.retiring_handles.is_empty()
          }

          pub fn has_any_active_or_unflushed_state(&self) -> bool {
              self.has_unflushed_obligations()
                  || self.handles.iter().any(|&h| self.handle_has_held_state(h))
          }

          pub async fn consume(
              &mut self,
              event: Event,
              handle: EmulationHandle,
          ) -> Result<(), EmulationError> {
              if self.retiring_handles.contains(&handle) {
                  return Ok(());
              }
              if self.pending_release.contains(&handle) && !self.release_keys(handle).await? {
                  return Ok(());
              }
              match event {
                  Event::Keyboard(KeyboardEvent::Key { key, state, .. }) => {
                      if !self.emulation.can_accept_and_flush()? {
                          if state == 0 && self.pressed_keys.get(&handle).is_some_and(|k| k.contains(&key)) {
                              self.pending_release.insert(handle);
                          }
                          return Ok(());
                      }
                      if self.update_pressed_keys(handle, key, state) {
                          self.emulation.consume(event, handle).await?;
                          if state == 0 && !self.emulation.is_flushed()? {
                              self.pending_release.insert(handle);
                          }
                      }
                      Ok(())
                  }
                  Event::Pointer(PointerEvent::Button { button, state, .. }) => {
                      if !self.emulation.can_accept_and_flush()? {
                          if state == 0 && self.pressed_buttons.get(&handle).is_some_and(|b| b.contains(&button)) {
                              self.pending_release.insert(handle);
                          }
                          return Ok(());
                      }
                      if self.update_pressed_buttons(handle, button, state) {
                          self.emulation.consume(event, handle).await?;
                          if state == 0 && !self.emulation.is_flushed()? {
                              self.pending_release.insert(handle);
                          }
                      }
                      Ok(())
                  }
                  Event::Keyboard(KeyboardEvent::Modifiers {
                      depressed,
                      latched,
                      locked,
                      group,
                  }) => {
                      if !self.emulation.can_accept_and_flush()? {
                          if (depressed | latched | locked | group) == 0 && self.dirty_modifiers.contains(&handle) {
                              self.pending_release.insert(handle);
                          }
                          return Ok(());
                      }
                      if (depressed | latched | locked | group) != 0 {
                          self.dirty_modifiers.insert(handle);
                      } else {
                          self.dirty_modifiers.remove(&handle);
                      }
                      self.emulation.consume(event, handle).await?;
                      if (depressed | latched | locked | group) == 0 && !self.emulation.is_flushed()? {
                          self.pending_release.insert(handle);
                      }
                      Ok(())
                  }
                  _ => self.emulation.consume(event, handle).await,
              }
          }

          pub async fn create(&mut self, handle: EmulationHandle) -> bool {
              if self.retiring_handles.contains(&handle) {
                  self.handles.insert(handle);
                  self.recreated_while_retiring.insert(handle);
                  return true;
              }
              if self.handles.insert(handle) {
                  self.pressed_keys.entry(handle).or_default();
                  self.pressed_buttons.entry(handle).or_default();
                  self.emulation.create(handle).await;
                  true
              } else {
                  false
              }
          }

          pub async fn destroy(&mut self, handle: EmulationHandle) {
              self.recreated_while_retiring.remove(&handle);
              let removed = self.handles.remove(&handle);
              if self.handle_has_held_state(handle) || self.pending_release.contains(&handle) {
                  self.pending_release.insert(handle);
              }
              if removed || self.handle_has_held_state(handle) || self.pending_release.contains(&handle) {
                  self.retiring_handles.insert(handle);
              }
              let flushed = match self.release_keys(handle).await {
                  Ok(done) => done,
                  Err(_) => {
                      self.backend_failed = true;
                      false
                  }
              };
              if flushed && !self.recreated_while_retiring.contains(&handle) {
                  self.retiring_handles.remove(&handle);
                  self.pending_release.remove(&handle);
                  self.pressed_keys.remove(&handle);
                  self.pressed_buttons.remove(&handle);
                  self.dirty_modifiers.remove(&handle);
                  self.emulation.destroy(handle).await;
              }
          }

          pub async fn drive_pending_releases(&mut self) -> Result<bool, EmulationError> {
              let targets: Vec<EmulationHandle> = self
                  .pending_release
                  .iter()
                  .chain(self.retiring_handles.iter())
                  .copied()
                  .collect::<BTreeSet<_>>()
                  .into_iter()
                  .collect();
              for handle in targets {
                  if !self.release_keys(handle).await? {
                      return Ok(false);
                  }
                  if self.retiring_handles.remove(&handle) {
                      if self.recreated_while_retiring.remove(&handle) {
                          // Keep live VirtualInput for recreated handle.
                      } else if !self.handles.contains(&handle) {
                          self.pressed_keys.remove(&handle);
                          self.pressed_buttons.remove(&handle);
                          self.dirty_modifiers.remove(&handle);
                          self.emulation.destroy(handle).await;
                      }
                  }
              }
              Ok(!self.has_unflushed_obligations() && self.emulation.is_flushed()?)
          }

          pub async fn terminate(&mut self) -> bool {
              let all_handles: Vec<EmulationHandle> = self
                  .handles
                  .iter()
                  .chain(self.retiring_handles.iter())
                  .copied()
                  .collect::<BTreeSet<_>>()
                  .into_iter()
                  .collect();
              for handle in all_handles {
                  self.destroy(handle).await;
              }
              for _ in 0..10 {
                  if self.backend_failed || !self.has_unflushed_obligations() {
                      break;
                  }
                  tokio::time::sleep(Duration::from_millis(5)).await;
                  match self.drive_pending_releases().await {
                      Ok(true) => break,
                      Ok(false) => continue,
                      Err(_) => {
                          self.backend_failed = true;
                          break;
                      }
                  }
              }
              let clean = !self.backend_failed
                  && !self.has_any_active_or_unflushed_state()
                  && matches!(self.emulation.is_flushed(), Ok(true));
              if clean {
                  self.emulation.terminate().await;
              }
              clean
          }

          pub async fn release_keys(&mut self, handle: EmulationHandle) -> Result<bool, EmulationError> {
              if !self.handles.contains(&handle) && !self.retiring_handles.contains(&handle) {
                  return Ok(false);
              }
              if self.handle_has_held_state(handle) {
                  self.pending_release.insert(handle);
              }

              let buttons: Vec<u32> = self
                  .pressed_buttons
                  .get(&handle)
                  .map(|b| b.iter().copied().collect())
                  .unwrap_or_default();
              for button in buttons {
                  if !self.emulation.can_accept_and_flush()? {
                      return Ok(false);
                  }
                  let event = Event::Pointer(PointerEvent::Button {
                      time: 0,
                      button,
                      state: 0,
                  });
                  self.emulation.consume(event, handle).await?;
                  if let Some(set) = self.pressed_buttons.get_mut(&handle) {
                      set.remove(&button);
                  }
              }

              let keys: Vec<u32> = self
                  .pressed_keys
                  .get(&handle)
                  .map(|k| k.iter().copied().collect())
                  .unwrap_or_default();
              for key in keys {
                  if !self.emulation.can_accept_and_flush()? {
                      return Ok(false);
                  }
                  let event = Event::Keyboard(KeyboardEvent::Key {
                      time: 0,
                      key,
                      state: 0,
                  });
                  self.emulation.consume(event, handle).await?;
                  if let Some(set) = self.pressed_keys.get_mut(&handle) {
                      set.remove(&key);
                  }
                  if let Ok(key) = input_event::scancode::Linux::try_from(key) {
                      log::warn!("releasing stuck key: {key:?}");
                  }
              }

              if self.dirty_modifiers.contains(&handle) || self.pending_release.contains(&handle) {
                  if !self.emulation.can_accept_and_flush()? {
                      return Ok(false);
                  }
                  let event = Event::Keyboard(KeyboardEvent::Modifiers {
                      depressed: 0,
                      latched: 0,
                      locked: 0,
                      group: 0,
                  });
                  self.emulation.consume(event, handle).await?;
                  self.dirty_modifiers.remove(&handle);
              }

              if !self.emulation.is_flushed()? {
                  return Ok(false);
              }
              self.pending_release.remove(&handle);
              Ok(true)
          }

          pub fn has_pressed_keys(&self, handle: EmulationHandle) -> bool {
              self.handle_has_held_state(handle) || self.pending_release.contains(&handle)
          }

          fn update_pressed_keys(&mut self, handle: EmulationHandle, key: u32, state: u8) -> bool {
              let Some(pressed_keys) = self.pressed_keys.get_mut(&handle) else {
                  return false;
              };
              if state == 0 {
                  pressed_keys.remove(&key)
              } else {
                  pressed_keys.insert(key)
              }
          }

          fn update_pressed_buttons(&mut self, handle: EmulationHandle, button: u32, state: u32) -> bool {
              let Some(pressed_buttons) = self.pressed_buttons.get_mut(&handle) else {
                  return false;
              };
              if state == 0 {
                  pressed_buttons.remove(&button)
              } else {
                  pressed_buttons.insert(button)
              }
          }"""
      assert old_lib_methods in lib_rs, "lib methods anchor missing"
      lib_rs = lib_rs.replace(old_lib_methods, new_lib_methods, 1)

      old_lib_trait = """    async fn destroy(&mut self, handle: EmulationHandle);
          async fn terminate(&mut self);
      }"""
      new_lib_trait = """    async fn destroy(&mut self, handle: EmulationHandle);
          async fn terminate(&mut self);
          fn bound_compositor_lifetime_id(&self) -> Option<&str> {
              None
          }
          fn can_accept_and_flush(&mut self) -> Result<bool, EmulationError> {
              Ok(true)
          }
          fn is_flushed(&mut self) -> Result<bool, EmulationError> {
              Ok(true)
          }
      }"""
      assert old_lib_trait in lib_rs, "lib trait anchor missing"
      lib_rs = lib_rs.replace(old_lib_trait, new_lib_trait, 1)
      lib_path.write_text(lib_rs)

      # V5-1, V6-1..V6-3, V7-1, V7-3, V8-1: emulation_task.rs
      emu_task_path = Path("src/server/emulation_task.rs")
      emu_task_path.write_text("""use local_channel::mpsc::{Receiver, Sender};
      use std::io;
      use std::net::SocketAddr;
      use std::path::{Path, PathBuf};
      use std::time::Duration;

      use lan_mouse_proto::ProtoEvent;
      use tokio::task::JoinHandle;
      use tokio::time::Instant;

      use lan_mouse_ipc::ClientHandle;

      use crate::{client::ClientManager, server::State};
      use input_emulation::{self, EmulationError, EmulationHandle, InputEmulation, InputEmulationError};
      use lan_mouse_ipc::Status;

      use super::{network_task::NetworkError, Server};

      #[derive(Clone, Debug)]
      pub(crate) enum EmulationRequest {
          Create(EmulationHandle),
          Destroy(EmulationHandle),
          ReleaseKeys(ClientHandle),
      }

      #[derive(Clone, Copy, Debug, PartialEq, Eq)]
      enum SeatState {
          Clean,
          Dirty,
          Unrecovered,
      }

      impl SeatState {
          fn as_str(self) -> &'static str {
              match self {
                  Self::Clean => "CLEAN",
                  Self::Dirty => "DIRTY",
                  Self::Unrecovered => "UNRECOVERED",
              }
          }
      }

      #[derive(Clone, Debug)]
      struct SeatRecord {
          lifetime_id: String,
          state: SeatState,
          serial_established: bool,
      }

      struct ConsumerResetState {
          floor_file: Option<PathBuf>,
          seat_file: Option<PathBuf>,
          bound_id: Option<String>,
          persisted_state: Option<SeatState>,
          serial_established: bool,
          highest_reset_serial: u32,
          unrecovered_teardown: bool,
      }

      impl ConsumerResetState {
          fn from_env() -> Self {
              Self {
                  floor_file: std::env::var_os("LAN_MOUSE_SERIAL_FLOOR_FILE").map(PathBuf::from),
                  seat_file: std::env::var_os("LAN_MOUSE_SEAT_STATE_FILE").map(PathBuf::from),
                  bound_id: None,
                  persisted_state: None,
                  serial_established: false,
                  highest_reset_serial: 0,
                  unrecovered_teardown: false,
              }
          }

          fn atomic_write(path: &Path, body: &str) -> io::Result<()> {
              let tmp = path.with_extension("tmp");
              std::fs::write(&tmp, body)?;
              std::fs::rename(&tmp, path)?;
              Ok(())
          }

          fn read_floor(path: &Path) -> Result<Option<u32>, ()> {
              match std::fs::read_to_string(path) {
                  Ok(text) => {
                      let trimmed = text.trim();
                      if let Some(val) = trimmed.strip_prefix("floor=") {
                          val.parse::<u32>().map(Some).map_err(|_| ())
                      } else {
                          trimmed.parse::<u32>().map(Some).map_err(|_| ())
                      }
                  }
                  Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
                  Err(_) => Err(()),
              }
          }

          fn read_seat(path: &Path) -> Result<Option<SeatRecord>, ()> {
              match std::fs::read_to_string(path) {
                  Ok(text) => {
                      let mut lifetime_id = None;
                      let mut state = None;
                      let mut serial_established = None;
                      for line in text.lines() {
                          if let Some(v) = line.strip_prefix("lifetime_id=") {
                              lifetime_id = Some(v.to_string());
                          } else if let Some(v) = line.strip_prefix("state=") {
                              state = match v {
                                  "CLEAN" => Some(SeatState::Clean),
                                  "DIRTY" => Some(SeatState::Dirty),
                                  "UNRECOVERED" => Some(SeatState::Unrecovered),
                                  _ => return Err(()),
                              };
                          } else if let Some(v) = line.strip_prefix("serial_established=") {
                              serial_established = match v {
                                  "0" => Some(false),
                                  "1" => Some(true),
                                  _ => return Err(()),
                              };
                          }
                      }
                      match (lifetime_id, state, serial_established) {
                          (Some(lifetime_id), Some(state), Some(serial_established)) => Ok(Some(SeatRecord {
                              lifetime_id,
                              state,
                              serial_established,
                          })),
                          _ => Err(()),
                      }
                  }
                  Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
                  Err(_) => Err(()),
              }
          }

          fn persist_seat_state(&mut self, bound_id: &str, desired: SeatState) {
              let effective = if self.unrecovered_teardown || self.persisted_state == Some(SeatState::Unrecovered) {
                  self.unrecovered_teardown = true;
                  SeatState::Unrecovered
              } else {
                  desired
              };
              let established = self.serial_established || effective == SeatState::Unrecovered;
              self.serial_established = established;
              self.persisted_state = Some(effective);
              self.bound_id = Some(bound_id.to_string());
              if let Some(path) = &self.seat_file {
                  let body = format!(
                      "lifetime_id={bound_id}\\nstate={}\\nserial_established={}\\n",
                      effective.as_str(),
                      if established { 1 } else { 0 }
                  );
                  if Self::atomic_write(path, &body).is_err() {
                      self.unrecovered_teardown = true;
                      self.persisted_state = Some(SeatState::Unrecovered);
                      self.serial_established = true;
                  }
              }
          }

          fn latch_unrecovered(&mut self, bound_id: &str) {
              self.unrecovered_teardown = true;
              self.serial_established = true;
              self.persist_seat_state(bound_id, SeatState::Unrecovered);
          }

          fn reconcile_bound_backend(&mut self, bound_id: Option<&str>) {
              let Some(bound_id) = bound_id else {
                  self.unrecovered_teardown = true;
                  self.serial_established = true;
                  return;
              };
              self.bound_id = Some(bound_id.to_string());

              let (Some(floor_path), Some(seat_path)) = (&self.floor_file, &self.seat_file) else {
                  return;
              };

              let floor_res = Self::read_floor(floor_path);
              let seat_res = Self::read_seat(seat_path);
              match (seat_res, floor_res) {
                  (Ok(None), Ok(None)) => {
                      self.highest_reset_serial = 0;
                      self.serial_established = false;
                      self.unrecovered_teardown = false;
                      self.persisted_state = None;
                      self.persist_seat_state(bound_id, SeatState::Clean);
                  }
                  (Ok(None), Ok(Some(_))) => {
                      self.latch_unrecovered(bound_id);
                  }
                  (Ok(Some(seat)), Ok(None)) => {
                      if !seat.serial_established && seat.state == SeatState::Clean && seat.lifetime_id == bound_id {
                          self.highest_reset_serial = 0;
                          self.serial_established = false;
                          self.unrecovered_teardown = false;
                          self.persisted_state = Some(SeatState::Clean);
                      } else {
                          self.latch_unrecovered(bound_id);
                      }
                  }
                  (Ok(Some(seat)), Ok(Some(floor))) => {
                      if floor == u32::MAX || (floor >= 1 && !seat.serial_established) {
                          self.latch_unrecovered(bound_id);
                          return;
                      }
                      self.highest_reset_serial = floor;
                      let same_compositor = seat.lifetime_id == bound_id;
                      if same_compositor && seat.state != SeatState::Clean {
                          self.latch_unrecovered(bound_id);
                          return;
                      }
                      if !same_compositor {
                          self.unrecovered_teardown = false;
                          self.persisted_state = Some(SeatState::Clean);
                      } else {
                          self.persisted_state = Some(seat.state);
                      }
                      if !self.unrecovered_teardown && !seat.serial_established {
                          self.serial_established = true;
                      } else {
                          self.serial_established = seat.serial_established;
                      }
                      self.persist_seat_state(bound_id, SeatState::Clean);
                  }
                  _ => {
                      self.latch_unrecovered(bound_id);
                  }
              }
          }

          fn maybe_establish_on_packet(&mut self) {
              if self.serial_established || self.unrecovered_teardown {
                  return;
              }
              let (Some(floor_path), Some(bound_id)) = (&self.floor_file, self.bound_id.clone()) else {
                  return;
              };
              match Self::read_floor(floor_path) {
                  Ok(Some(0)) => {
                      self.serial_established = true;
                      let desired = self.persisted_state.unwrap_or(SeatState::Clean);
                      self.persist_seat_state(&bound_id, desired);
                  }
                  Ok(None) => {}
                  _ => {
                      self.latch_unrecovered(&bound_id);
                  }
              }
          }

          fn mark_dirty_before_input(&mut self) {
              if self.unrecovered_teardown {
                  return;
              }
              if self.persisted_state == Some(SeatState::Clean) {
                  if let Some(bound_id) = self.bound_id.clone() {
                      self.persist_seat_state(&bound_id, SeatState::Dirty);
                  }
              }
          }

          fn maybe_mark_clean(&mut self, emulation: &mut InputEmulation) {
              if self.unrecovered_teardown
                  || self.persisted_state != Some(SeatState::Dirty)
                  || emulation.backend_failed
                  || emulation.has_any_active_or_unflushed_state()
                  || !matches!(emulation.is_flushed(), Ok(true))
              {
                  return;
              }
              if let Some(bound_id) = self.bound_id.clone() {
                  self.persist_seat_state(&bound_id, SeatState::Clean);
              }
          }

          fn finalize_terminate(&mut self, clean: bool) {
              if let Some(bound_id) = self.bound_id.clone() {
                  if clean {
                      if self.persisted_state == Some(SeatState::Dirty) {
                          self.persist_seat_state(&bound_id, SeatState::Clean);
                      }
                  } else {
                      self.latch_unrecovered(&bound_id);
                  }
              }
          }
      }

      pub(crate) fn new(
          server: Server,
          emulation_rx: Receiver<EmulationRequest>,
          udp_rx: Receiver<Result<(ProtoEvent, SocketAddr), NetworkError>>,
          sender_tx: Sender<(ProtoEvent, SocketAddr)>,
      ) -> JoinHandle<()> {
          let emulation_task = emulation_task(server, emulation_rx, udp_rx, sender_tx);
          tokio::task::spawn_local(emulation_task)
      }

      async fn emulation_task(
          server: Server,
          mut rx: Receiver<EmulationRequest>,
          mut udp_rx: Receiver<Result<(ProtoEvent, SocketAddr), NetworkError>>,
          sender_tx: Sender<(ProtoEvent, SocketAddr)>,
      ) {
          let mut reset_state = ConsumerResetState::from_env();
          loop {
              if let Err(e) = do_emulation(&server, &mut rx, &mut udp_rx, &sender_tx, &mut reset_state).await {
                  log::warn!("input emulation exited: {e}");
              }
              server.set_emulation_status(Status::Disabled);
              if server.is_cancelled() {
                  break;
              }

              loop {
                  tokio::select! {
                      _ = rx.recv() => continue,
                      _ = server.emulation_notified() => break,
                      _ = server.cancelled() => return,
                  }
              }
          }
      }

      async fn do_emulation(
          server: &Server,
          rx: &mut Receiver<EmulationRequest>,
          udp_rx: &mut Receiver<Result<(ProtoEvent, SocketAddr), NetworkError>>,
          sender_tx: &Sender<(ProtoEvent, SocketAddr)>,
          reset_state: &mut ConsumerResetState,
      ) -> Result<(), InputEmulationError> {
          let backend = server.config.emulation_backend.map(|b| b.into());
          log::info!("creating input emulation...");
          let mut emulation = tokio::select! {
              r = InputEmulation::new(backend) => r?,
              _ = server.cancelled() => return Ok(()),
          };

          reset_state.reconcile_bound_backend(emulation.bound_compositor_lifetime_id());
          server.set_emulation_status(Status::Enabled);

          for handle in server.active_clients() {
              emulation.create(handle).await;
          }

          let res = do_emulation_session(server, &mut emulation, rx, udp_rx, sender_tx, reset_state).await;
          let clean = emulation.terminate().await;
          reset_state.finalize_terminate(clean);
          res
      }

      async fn do_emulation_session(
          server: &Server,
          emulation: &mut InputEmulation,
          rx: &mut Receiver<EmulationRequest>,
          udp_rx: &mut Receiver<Result<(ProtoEvent, SocketAddr), NetworkError>>,
          sender_tx: &Sender<(ProtoEvent, SocketAddr)>,
          reset_state: &mut ConsumerResetState,
      ) -> Result<(), InputEmulationError> {
          let mut last_ignored = None;
          let mut retry_sleep = Box::pin(tokio::time::sleep(Duration::from_millis(10)));
          let mut retry_armed = false;

          loop {
              if !emulation.backend_failed && emulation.has_unflushed_obligations() {
                  if !retry_armed {
                      retry_sleep.as_mut().reset(Instant::now() + Duration::from_millis(10));
                      retry_armed = true;
                  }
              } else {
                  retry_armed = false;
              }

              tokio::select! {
                  biased;
                  _ = server.notifies.cancel.cancelled() => break Ok(()),
                  _ = &mut retry_sleep, if retry_armed => {
                      match emulation.drive_pending_releases().await {
                          Ok(true) => {
                              retry_armed = false;
                              reset_state.maybe_mark_clean(emulation);
                          }
                          Ok(false) => {
                              retry_sleep.as_mut().reset(Instant::now() + Duration::from_millis(10));
                          }
                          Err(e) => {
                              emulation.backend_failed = true;
                              if let Some(bound_id) = reset_state.bound_id.clone() {
                                  reset_state.latch_unrecovered(&bound_id);
                              }
                              break Err(e.into());
                          }
                      }
                  }
                  emulate_event = rx.recv() => {
                      match emulate_event.expect("channel closed") {
                          EmulationRequest::Create(h) => { let _ = emulation.create(h).await; },
                          EmulationRequest::Destroy(h) => {
                              emulation.destroy(h).await;
                              reset_state.maybe_mark_clean(emulation);
                          }
                          EmulationRequest::ReleaseKeys(c) => {
                              let _ = emulation.release_keys(c).await?;
                              server.update_pressed_keys(c, emulation.has_pressed_keys(c));
                              reset_state.maybe_mark_clean(emulation);
                          }
                      }
                  }
                  udp_event = udp_rx.recv() => {
                      let udp_event = match udp_event.expect("channel closed") {
                          Ok(e) => e,
                          Err(e) => {
                              log::warn!("network error: {e}");
                              continue;
                          }
                      };
                      handle_incoming_event(server, emulation, sender_tx, &mut last_ignored, udp_event, reset_state).await?;
                  }
              }
          }
      }

      async fn handle_incoming_event(
          server: &Server,
          emulate: &mut InputEmulation,
          sender_tx: &Sender<(ProtoEvent, SocketAddr)>,
          last_ignored: &mut Option<SocketAddr>,
          event: (ProtoEvent, SocketAddr),
          reset_state: &mut ConsumerResetState,
      ) -> Result<(), EmulationError> {
          let (event, addr) = event;

          log::trace!("{:20} <-<-<-<------ {addr}", event.to_string());

          let Some(handle) =
              activate_client_if_exists(&mut server.client_manager.borrow_mut(), addr, last_ignored)
          else {
              return Ok(());
          };

          reset_state.maybe_establish_on_packet();

          match (event, addr) {
              (ProtoEvent::Pong, _) => {}
              (ProtoEvent::Ping, addr) => {
                  let _ = sender_tx.send((ProtoEvent::Pong, addr));
              }
              (ProtoEvent::Leave(serial), addr) => {
                  if serial == 0 {
                      let _ = emulate.release_keys(handle).await?;
                      reset_state.maybe_mark_clean(emulate);
                  } else if reset_state.serial_established
                      && !reset_state.unrecovered_teardown
                      && serial > reset_state.highest_reset_serial
                  {
                      reset_state.highest_reset_serial = serial;
                      let flushed = emulate.release_keys(handle).await?;
                      reset_state.maybe_mark_clean(emulate);
                      if flushed && !emulate.has_unflushed_obligations() {
                          let _ = sender_tx.send((ProtoEvent::Ack(serial), addr));
                      }
                  }
              }
              (ProtoEvent::Ack(_), _) => server.set_state(State::Sending),
              (ProtoEvent::Enter(_), _) => {
                  server.set_state(State::Receiving);
                  let _ = sender_tx.send((ProtoEvent::Ack(0), addr));
              }
              (ProtoEvent::Input(e), _) => {
                  if reset_state.unrecovered_teardown {
                      return Ok(());
                  }
                  if let State::Receiving = server.get_state() {
                      log::trace!("{event} => emulate");
                      reset_state.mark_dirty_before_input();
                      if reset_state.unrecovered_teardown {
                          return Ok(());
                      }
                      emulate.consume(e, handle).await?;
                      let has_pressed_keys = emulate.has_pressed_keys(handle);
                      server.update_pressed_keys(handle, has_pressed_keys);
                      if has_pressed_keys {
                          server.restart_ping_timer();
                      }
                  }
              }
          }
          Ok(())
      }

      fn activate_client_if_exists(
          client_manager: &mut ClientManager,
          addr: SocketAddr,
          last_ignored: &mut Option<SocketAddr>,
      ) -> Option<ClientHandle> {
          let Some(handle) = client_manager.get_client(addr) else {
              if last_ignored.is_none() || last_ignored.is_some() && last_ignored.unwrap() != addr {
                  log::warn!("ignoring events from client {addr}");
                  last_ignored.replace(addr);
              }
              return None;
          };
          last_ignored.take();

          let (_, client_state) = client_manager.get_mut(handle)?;
          client_state.alive = true;
          client_state.active_addr = Some(addr);
          Some(handle)
      }
      """)
      PY

      ! grep -Fq 'keys.drain()' input-emulation/src/lib.rs
    '';
  });
  port = 4242;
  loopback = "127.0.0.1:${toString port}";
  bridgePort = 4243;
  bridgeLanPort = 4244;
  release = ''["KeyScrollLock"]'';
  role =
    if hostName == "workstation" then
      "listen"
    else if hostName == "prl-dev-vm" then
      "dial"
    else
      null;
in
lib.mkIf (role != null) {
  home.packages = [
    lanMouse
    bridge
  ];

  xdg.configFile."lan-mouse/config.toml".text =
    if role == "listen" then
      ''
        port = ${toString port}
        capture_backend = "layer-shell"
        emulation_backend = "wlroots"
        release_bind = ${release}

        [right]
        ips = ["127.0.0.1"]
        port = ${toString bridgeLanPort}
        activate_on_startup = true
      ''
    else
      ''
        port = ${toString port}
        capture_backend = "layer-shell"
        emulation_backend = "wlroots"
        release_bind = ${release}

        [left]
        ips = ["127.0.0.1"]
        port = ${toString bridgeLanPort}
        activate_on_startup = true
      '';

  systemd.user.services.lan-mouse = {
    Unit = {
      Description = "Share the keyboard and pointer with the other machine";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      ExecStart = [ "${lib.getExe lanMouse} --daemon" ];
      Environment = [
        "LAN_MOUSE_SERIAL_FLOOR_FILE=%t/cursor-bridge/bridge-serial"
        "LAN_MOUSE_SEAT_STATE_FILE=%t/cursor-bridge/native-seat"
      ];
      RuntimeDirectory = "cursor-bridge";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = "yes";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  systemd.user.services.cursor-bridge = {
    Unit = {
      Description = "Carry the shared pointer across one connection";
      After = [
        "graphical-session.target"
        "lan-mouse.service"
      ];
      PartOf = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      ExecStart = [
        (
          if role == "listen" then
            "${lib.getExe bridge} --listen --quic-addr 0.0.0.0:${toString bridgePort} --lan-local 127.0.0.1:${toString bridgeLanPort} --lan-peer ${loopback} --cert %d/cert --key %d/key --niri-bin ${lib.getExe unstable-pkgs.niri} --busctl-bin ${pkgs.systemd}/bin/busctl --enter-output ${config.my.displays.dp2} --serial-floor-file %t/cursor-bridge/bridge-serial --seat-state-file %t/cursor-bridge/native-seat --clipboard"
          else
            "${lib.getExe bridge} --dial --quic-addr 192.168.10.75:${toString bridgePort} --lan-local 127.0.0.1:${toString bridgeLanPort} --lan-peer ${loopback} --cert %d/cert --key %d/key --serial-floor-file %t/cursor-bridge/bridge-serial --seat-state-file %t/cursor-bridge/native-seat --clipboard"
        )
      ];
      LoadCredential = [
        "cert:${osConfig.sops.secrets."cursor-bridge/cert".path}"
        "key:${osConfig.sops.secrets."cursor-bridge/key".path}"
      ];
      RuntimeDirectory = "cursor-bridge";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = "yes";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
