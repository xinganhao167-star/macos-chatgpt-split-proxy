#!/usr/bin/env python3
# SNI 透传中继：监听 127.0.0.1:443，从 TLS ClientHello 里读出目标域名，
# 通过本地 SOCKS5 代理（默认 Anycast 127.0.0.1:1080，远程解析）建连后双向转发。
# 端到端 TLS 原样透传，不做任何中间人，证书校验不受影响。
# 用法： sni-relay.py [监听地址] [监听端口] [SOCKS地址:端口]
import asyncio
import socket
import struct
import sys
from typing import Optional, Tuple

LISTEN_HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
LISTEN_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 443
SOCKS_TARGET = sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1:1080"
IDLE_TIMEOUT = 300


def log(msg: str) -> None:
    sys.stdout.write(f"[relay] {msg}\n")
    sys.stdout.flush()


def parse_sni(data: bytes) -> Optional[str]:
    """从一段 TLS 记录字节里解析 ClientHello 的 SNI 域名；解析不出返回 None。"""
    try:
        if len(data) < 5 or data[0] != 0x16:  # 非 handshake 记录
            return None
        rec_len = struct.unpack("!H", data[3:5])[0]
        if len(data) < 5 + rec_len:
            return None
        hs = data[5 : 5 + rec_len]
        if hs[0] != 0x01:  # 非 ClientHello
            return None
        p = 4  # 跳过 type(1)+len(3)
        p += 2 + 32  # client version + random
        sid_len = hs[p]
        p += 1 + sid_len
        cs_len = struct.unpack("!H", hs[p : p + 2])[0]
        p += 2 + cs_len
        comp_len = hs[p]
        p += 1 + comp_len
        ext_total = struct.unpack("!H", hs[p : p + 2])[0]
        p += 2
        end = p + ext_total
        while p + 4 <= min(end, len(hs)):
            etype, elen = struct.unpack("!HH", hs[p : p + 4])
            ebody = hs[p + 4 : p + 4 + elen]
            p += 4 + elen
            if etype == 0x0000 and len(ebody) >= 5 and ebody[2] == 0x00:
                # ebody = list_len(2) + name_type(1) + name_len(2) + hostname
                nlen = struct.unpack("!H", ebody[3:5])[0]
                return ebody[5 : 5 + nlen].decode("ascii", "replace").lower()
        return None
    except Exception:
        return None


async def socks_connect(host: str, port: int) -> Tuple[asyncio.StreamReader, asyncio.StreamReader, asyncio.StreamWriter]:
    s_host, _, s_port = SOCKS_TARGET.rpartition(":")
    r, w = await asyncio.wait_for(
        asyncio.open_connection(s_host or "127.0.0.1", int(s_port)), timeout=10
    )
    w.write(b"\x05\x01\x00")
    await w.drain()
    resp = await asyncio.wait_for(r.readexactly(2), timeout=10)
    if resp[0] != 0x05 or resp[1] != 0x00:
        raise OSError(f"socks greet fail: {resp.hex()}")
    h = host.encode("idna")
    w.write(b"\x05\x01\x00\x03" + bytes([len(h)]) + h + struct.pack("!H", port))
    await w.drain()
    resp = await asyncio.wait_for(r.readexactly(4), timeout=15)
    if resp[1] != 0x00:
        raise OSError(f"socks connect fail: code={resp[1]}")
    atyp = resp[3]
    if atyp == 0x01:
        await r.readexactly(4 + 2)
    elif atyp == 0x03:
        n = (await r.readexactly(1))[0]
        await r.readexactly(n + 2)
    elif atyp == 0x04:
        await r.readexactly(16 + 2)
    return r, r, w


async def pipe(src: asyncio.StreamReader, dst: asyncio.StreamWriter) -> None:
    try:
        while True:
            chunk = await src.read(65536)
            if not chunk:
                break
            dst.write(chunk)
            await dst.drain()
    except Exception:
        pass
    finally:
        try:
            if dst.can_write_eof():
                dst.write_eof()
        except Exception:
            pass


async def handle(client_r: asyncio.StreamReader, client_w: asyncio.StreamWriter) -> None:
    peer = client_w.get_extra_info("peername")
    host = None
    upstream_r = upstream_w = None
    try:
        # 先读到完整第一条 TLS 记录（ClientHello），才能拿 SNI
        header = await asyncio.wait_for(client_r.readexactly(5), timeout=15)
        rec_len = struct.unpack("!H", header[3:5])[0]
        body = b""
        if rec_len:
            body = await asyncio.wait_for(client_r.readexactly(rec_len), timeout=15)
        hello = header + body
        host = parse_sni(hello)
        if not host:
            log(f"no sni from {peer}, close")
            return
        upstream_r, _, upstream_w = await socks_connect(host, 443)
        upstream_w.write(hello)
        await upstream_w.drain()
        log(f"{peer[0]}:{peer[1]} -> {host}:443 via socks ok")
        await asyncio.gather(
            pipe(client_r, upstream_w), pipe(upstream_r, client_w), return_exceptions=True
        )
    except Exception as e:
        log(f"{peer} {host or '?'}: {e!r}")
    finally:
        for w in (client_w, upstream_w):
            if w is not None:
                try:
                    w.close()
                except Exception:
                    pass


async def main() -> None:
    server = await asyncio.start_server(handle, LISTEN_HOST, LISTEN_PORT)
    log(f"sni-relay listening on {LISTEN_HOST}:{LISTEN_PORT} -> socks {SOCKS_TARGET}")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
