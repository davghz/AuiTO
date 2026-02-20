import asyncio
import json
import sys
from contextlib import asynccontextmanager
from typing import Any, Dict, Optional


class _StdioReader:
    def __init__(self):
        self._stream = sys.stdin.buffer
        self.framing: Optional[str] = None

    async def read_message(self) -> Optional[Dict[str, Any]]:
        return await asyncio.to_thread(self._read_message_sync)

    def _read_message_sync(self) -> Optional[Dict[str, Any]]:
        first_line = self._stream.readline()
        if not first_line:
            return None

        # Support newline-delimited JSON-RPC framing used by some MCP clients.
        stripped = first_line.strip()
        if stripped.startswith((b"{", b"[")):
            self.framing = self.framing or "jsonl"
            return json.loads(stripped.decode("utf-8"))

        # Fall back to LSP-style Content-Length framing.
        content_length = None
        line = first_line
        while True:
            if not line:
                return None
            if line in (b"\r\n", b"\n"):
                break
            key, sep, value = line.decode("utf-8", errors="replace").partition(":")
            if sep and key.strip().lower() == "content-length":
                try:
                    content_length = int(value.strip())
                except ValueError:
                    content_length = None
            line = self._stream.readline()

        if content_length is None:
            return None

        self.framing = self.framing or "content-length"
        body = self._stream.read(content_length)
        if not body:
            return None
        return json.loads(body.decode("utf-8"))


class _StdioWriter:
    def __init__(self, reader: _StdioReader):
        self._stream = sys.stdout.buffer
        self._reader = reader
        self._lock = asyncio.Lock()

    async def write_message(self, message: Dict[str, Any]) -> None:
        payload = json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        async with self._lock:
            await asyncio.to_thread(self._write_sync, payload)

    def _write_sync(self, payload: bytes) -> None:
        if self._reader.framing == "jsonl":
            self._stream.write(payload)
            self._stream.write(b"\n")
        else:
            header = f"Content-Length: {len(payload)}\r\n\r\n".encode("ascii")
            self._stream.write(header)
            self._stream.write(payload)
        self._stream.flush()


@asynccontextmanager
async def stdio_server():
    reader = _StdioReader()
    writer = _StdioWriter(reader)
    yield reader, writer
