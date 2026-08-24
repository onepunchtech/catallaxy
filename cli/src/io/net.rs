//! Sockets the CLI opens on the host.

/// Try to bind a port, reporting only why it failed.
///
/// The caller decides what a failure means, because it is not one thing: a
/// port below 1024 refuses a non-root bind with `PermissionDenied` whether or
/// not anything holds it, while `AddrInUse` is a genuine conflict.
///
/// # Errors
///
/// The `ErrorKind` of whichever bind failed first, TCP or UDP. Both are tried
/// because a port is only free if both are.
pub fn try_bind(port: u16) -> Result<(), std::io::ErrorKind> {
    use std::net::{Ipv4Addr, SocketAddrV4, TcpListener, UdpSocket};

    let addr = SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, port);

    TcpListener::bind(addr).map_err(|e| e.kind())?;
    UdpSocket::bind(addr).map_err(|e| e.kind())?;
    Ok(())
}
