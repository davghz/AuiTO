from dataclasses import dataclass
from typing import Any, Dict


@dataclass
class Tool:
    name: str
    description: str
    inputSchema: Dict[str, Any]


@dataclass
class TextContent:
    type: str
    text: str


@dataclass
class ImageContent:
    type: str
    data: str
    mimeType: str

