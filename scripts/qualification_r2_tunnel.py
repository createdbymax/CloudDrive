"""Opaque HTTPS tunnel for dropping only a generated qualification owner's R2 connections."""
import asyncio
import threading


class R2Tunnel:
    def __init__(self):
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self.loop.run_forever, daemon=True)
        self.thread.start()
        self.peers = set()
        self.online = True
        self.forwarded = 0
        self.refused = 0
        self.server = self._run(asyncio.start_server(self._accept, "127.0.0.1", 0, limit=8192))
        self.port = self.server.sockets[0].getsockname()[1]

    def _run(self, coro):
        return asyncio.run_coroutine_threadsafe(coro, self.loop).result(timeout=10)

    def set_online(self, online):
        async def change():
            self.online = online
            if not online:
                for writer in tuple(self.peers):
                    writer.transport.abort()
        self._run(change())

    async def _accept(self, reader, writer):
        upstream = None
        pumps = []
        try:
            if not self.online:
                self.refused += 1
                return
            self.peers.add(writer)
            header = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=5)
            method, target, _ = header.split(b"\r\n", 1)[0].decode("ascii").split()
            host, port = target.rsplit(":", 1)
            if method != "CONNECT" or port != "443" or not host.endswith(".r2.cloudflarestorage.com"):
                return
            response, upstream = await asyncio.wait_for(asyncio.open_connection(host, 443), timeout=5)
            if not self.online:
                return
            self.peers.add(upstream)
            writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            await writer.drain()
            self.forwarded += 1

            async def copy(source, destination):
                while chunk := await source.read(65536):
                    destination.write(chunk)
                    await destination.drain()

            pumps = [asyncio.create_task(copy(reader, upstream)), asyncio.create_task(copy(response, writer))]
            await asyncio.wait(pumps, return_when=asyncio.FIRST_COMPLETED)
        except (OSError, ValueError, asyncio.IncompleteReadError, asyncio.LimitOverrunError):
            pass
        finally:
            for pump in pumps:
                pump.cancel()
            if pumps:
                await asyncio.gather(*pumps, return_exceptions=True)
            for peer in (writer, upstream):
                if peer:
                    self.peers.discard(peer)
                    peer.close()

    def close(self):
        self.set_online(False)
        async def stop():
            self.server.close()
            await self.server.wait_closed()
        self._run(stop())
        self.loop.call_soon_threadsafe(self.loop.stop)
        self.thread.join(timeout=5)
