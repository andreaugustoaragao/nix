package syslog

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	maxSyslogMsgBytes  = 16 << 10 // 16 KiB cap per frame
	maxSyslogConns     = 16
	syslogReadDeadline = 5 * time.Minute
)

// Receiver accepts source-restricted RFC 5424/3164 syslog events over TCP (RFC 6587 octet-counting or LF).
type Receiver struct {
	ln      net.Listener
	allowed map[string]bool
	handler func(Message)
	sem     chan struct{}
	wg      sync.WaitGroup
}

// Listen binds the TCP syslog listener immediately and validates source allowlist entries.
func Listen(addr string, allowedIPs []string, handler func(Message)) (*Receiver, error) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	allowed := make(map[string]bool, len(allowedIPs))
	for _, raw := range allowedIPs {
		t := strings.TrimSpace(raw)
		if t == "" {
			continue
		}
		if ip := net.ParseIP(t); ip != nil {
			allowed[ip.String()] = true
		} else {
			allowed[t] = true
		}
	}
	return &Receiver{
		ln:      ln,
		allowed: allowed,
		handler: handler,
		sem:     make(chan struct{}, maxSyslogConns),
	}, nil
}

// Addr returns the bound listener address.
func (r *Receiver) Addr() string {
	return r.ln.Addr().String()
}

// Serve accepts incoming syslog connections until ctx is canceled.
func (r *Receiver) Serve(ctx context.Context) error {
	go func() {
		<-ctx.Done()
		_ = r.ln.Close()
	}()

	for {
		conn, err := r.ln.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				r.wg.Wait()
				return nil
			}
			log.Printf("syslog accept error: %v", err)
			continue
		}
		if !r.isAllowedConn(conn.RemoteAddr()) {
			_ = conn.Close()
			continue
		}
		select {
		case r.sem <- struct{}{}:
		default:
			_ = conn.Close()
			continue
		}
		r.wg.Add(1)
		go func(c net.Conn) {
			defer r.wg.Done()
			defer func() {
				<-r.sem
				_ = c.Close()
			}()
			r.handleConn(ctx, c)
		}(conn)
	}
}

func (r *Receiver) isAllowedConn(remote net.Addr) bool {
	if len(r.allowed) == 0 {
		return false
	}
	tcpAddr, ok := remote.(*net.TCPAddr)
	if !ok || tcpAddr.IP == nil {
		host, _, err := net.SplitHostPort(remote.String())
		if err != nil {
			return false
		}
		if ip := net.ParseIP(host); ip != nil {
			return r.allowed[ip.String()]
		}
		return r.allowed[host]
	}
	return r.allowed[tcpAddr.IP.String()]
}

func (r *Receiver) handleConn(ctx context.Context, conn net.Conn) {
	br := bufio.NewReaderSize(conn, maxSyslogMsgBytes+64)
	for {
		if ctx.Err() != nil {
			return
		}
		_ = conn.SetReadDeadline(time.Now().Add(syslogReadDeadline))
		line, err := readSyslogFrame(br)
		if err != nil {
			return
		}
		if msg, ok := ParseLine(line, time.Now().UTC()); ok && r.handler != nil {
			r.handler(msg)
		}
	}
}

func readSyslogFrame(br *bufio.Reader) (string, error) {
	first, err := br.Peek(1)
	if err != nil {
		return "", err
	}
	// RFC 6587 octet-counting: <LEN> <MSG>
	if first[0] >= '0' && first[0] <= '9' {
		lenBuf := make([]byte, 0, 8)
		for {
			b, err := br.ReadByte()
			if err != nil {
				return "", err
			}
			if b == ' ' {
				break
			}
			if b < '0' || b > '9' || len(lenBuf) >= 6 {
				return "", errors.New("invalid RFC 6587 frame length")
			}
			lenBuf = append(lenBuf, b)
		}
		n, err := strconv.Atoi(string(lenBuf))
		if err != nil || n <= 0 || n > maxSyslogMsgBytes {
			return "", fmt.Errorf("invalid syslog frame length %d", n)
		}
		buf := make([]byte, n)
		if _, err := io.ReadFull(br, buf); err != nil {
			return "", err
		}
		return string(buf), nil
	}

	// Non-transparent LF framing with cap
	var line []byte
	for {
		frag, err := br.ReadSlice('\n')
		if len(line)+len(frag) > maxSyslogMsgBytes {
			return "", errors.New("syslog line exceeds 16 KiB limit")
		}
		line = append(line, frag...)
		if err == nil {
			break
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		if errors.Is(err, io.EOF) && len(line) > 0 {
			break
		}
		return "", err
	}
	return string(line), nil
}

// SendFixture transmits a single RFC 6587 octet-counted syslog message over TCP (used for tests & replay).
func SendFixture(addr, line string) error {
	trimmed := strings.TrimRight(line, "\r\n")
	if trimmed == "" {
		return errors.New("empty syslog fixture")
	}
	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	_ = conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	frame := fmt.Sprintf("%d %s", len(trimmed), trimmed)
	_, err = io.WriteString(conn, frame)
	return err
}
