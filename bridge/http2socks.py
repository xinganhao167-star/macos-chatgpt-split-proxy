#!/usr/bin/env python3
"""本地 HTTP→SOCKS5 桥：给桌面端一个 HTTP 代理入口，实际转发走 SOCKS5。

为什么需要它（2026-10-27 实测）：ChatGPT 桌面端直连 Anycast 的 HTTP 入站（8080）时，
Anycast 代理核心会持续占满一个核（实测平均 96%、峰值 99%，机器发烫）；
把同一份负载改走 Anycast 的 SOCKS 入站（1080）后，Anycast 回落到 0.1%。
同一个应用、相近的连接数，唯一差别是入站类型，因此这不是"长连接太多"，是 8080 那个实现的问题。

本桥的目的就是把桌面端从 8080 挪到 1080，同时不改 Anycast 的模式、不加 TUN、不改路由。

用法：
  http2socks.py --listen 8081 --socks 127.0.0.1:1080 [--idle 900]
  http2socks.py 8081 127.0.0.1:1080            # 兼容位置参数
只监听 127.0.0.1；只支持 HTTP 代理语义（CONNECT 与绝对 URI 请求）。
"""

import argparse
import asyncio
import struct
import sys
import time
from typing import List, Optional, Tuple

DEFAULT_LISTEN = 8081
DEFAULT_SOCKS = "127.0.0.1:1080"
DEFAULT_IDLE = 900

CONNECT_TIMEOUT = 10
SOCKS_REPLY_TIMEOUT = 15
HEAD_TIMEOUT = 30
MAX_HEAD = 65536


def log(msg: str) -> None:
    sys.stdout.write(f"[bridge {time.strftime('%H:%M:%S')}] {msg}\n")
    sys.stdout.flush()


async def socks_connect(socks: str, host: str, port: int) -> Tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    s_host, _, s_port = socks.rpartition(":")
    r, w = await asyncio.wait_for(
        asyncio.open_connection(s_host or "127.0.0.1", int(s_port)), timeout=CONNECT_TIMEOUT
    )
    w.write(b"\x05\x01\x00")
    await w.drain()
    resp = await asyncio.wait_for(r.readexactly(2), timeout=SOCKS_REPLY_TIMEOUT)
    if resp[0] != 0x05 or resp[1] != 0x00:
        raise OSError(f"socks greet fail: {resp.hex()}")
    h = host.encode("idna")
    w.write(b"\x05\x01\x00\x03" + bytes([len(h)]) + h + struct.pack("!H", port))
    await w.drain()
    resp = await asyncio.wait_for(r.readexactly(4), timeout=SOCKS_REPLY_TIMEOUT)
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
    return r, w


async def read_head(reader: asyncio.StreamReader) -> bytes:
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = await asyncio.wait_for(reader.read(8192), timeout=HEAD_TIMEOUT)
        if not chunk:
            break
        head += chunk
        if len(head) > MAX_HEAD:
            break
    return head


async def pipe(src: asyncio.StreamReader, dst: asyncio.StreamWriter, idle: int) -> None:
    try:
        while True:
            try:
                chunk = await asyncio.wait_for(src.read(65536), timeout=idle)
            except asyncio.TimeoutError:
                log(f"idle {idle}s，关闭连接")
                break
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


async def handle(cr: asyncio.StreamReader, cw: asyncio.StreamWriter, socks: str, idle: int) -> None:
    peer = cw.get_extra_info("peername")
    who = f"{peer[0]}:{peer[1]}" if peer else "?"
    uw = None
    try:
        head = await read_head(cr)
        if not head:
            return
        first, _, rest = head.partition(b"\r\n\r\n")
        lines = first.split(b"\r\n")
        parts = lines[0].split()
        if len(parts) < 2:
            cw.write(b"HTTP/1.1 400 Bad Request\r\n\r\n")
            return
        method, target = parts[0].upper(), parts[1].decode("latin-1")
        if method == b"CONNECT":
            host, _, port = target.rpartition(":")
            port = int(port or 443)
            ur, uw = await socks_connect(socks, host, port)
            cw.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            await cw.drain()
            if rest:
                uw.write(rest)
                await uw.drain()
        else:
            _, _, restpath = target.partition("://")
            if not restpath:
                cw.write(b"HTTP/1.1 400 Bad Request\r\n\r\n")
                return
            hostport, _, path = restpath.partition("/")
            host, _, port = hostport.rpartition(":")
            port = int(port) if port else 80
            ur, uw = await socks_connect(socks, host, port)
            newhead = b"\r\n".join([f"{parts[0].decode()} /{path}".encode(), *lines[1:]]) + b"\r\n\r\n"
            uw.write(newhead + rest)
            await uw.drain()
        log(f"{who} {method.decode()} {target[:100]} ok")
        await asyncio.gather(pipe(cr, uw, idle), pipe(ur, cw, idle), return_exceptions=True)
    except Exception as exc:
        log(f"{who} {exc!r}")
    finally:
        for w in (cw, uw):
            if w is not None:
                try:
                    w.close()
                except Exception:
                    pass


def parse_args(argv: List[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--listen", type=int, default=DEFAULT_LISTEN)
    parser.add_argument("--socks", default=DEFAULT_SOCKS)
    parser.add_argument("--idle", type=int, default=DEFAULT_IDLE)
    parser.add_argument("-h", "--help", action="store_true")
    known, rest = parser.parse_known_args(argv)
    if known.help:
        print(__doc__)
        sys.exit(0)
    vals = [a for a in rest if not a.startswith("-")]
    if vals:
        known.listen = int(vals[0])
    if len(vals) >= 2:
        known.socks = vals[1]
    return known


async def main() -> None:
    args = parse_args(sys.argv[1:])
    server = await asyncio.start_server(
        lambda r, w: handle(r, w, args.socks, args.idle), "127.0.0.1", args.listen
    )
    log(f"listening 127.0.0.1:{args.listen} -> socks {args.socks}")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
