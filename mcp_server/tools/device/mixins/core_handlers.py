"""Core device tool handlers."""

import base64
import hashlib
import json
import os
import time
from typing import List

from mcp.types import ImageContent, TextContent


class DeviceCoreHandlersMixin:
    async def _handle_ping(self) -> List[TextContent]:
        """Handle device_ping tool."""
        try:
            response = self._daemon_get("/ping")
        except Exception:
            response = self.client.get("/ping")
        return [TextContent(type="text", text=f"Device status: {response.text}")]

    async def _handle_state(self) -> List[TextContent]:
        """Handle device_state tool."""
        try:
            response = self._daemon_get("/state")
        except Exception:
            response = self.client.get("/state")
        return [TextContent(type="text", text=response.text)]

    async def _handle_tap(self, arguments: dict) -> List[TextContent]:
        """Handle device_tap tool."""
        x = arguments.get("x")
        y = arguments.get("y")
        method = arguments.get("method")
        pixel = arguments.get("pixel")

        # Strict non-AX methods must go through daemon (8876) so strict verification runs centrally.
        if self._is_strict_non_ax_method(method):
            params = {"x": x, "y": y, "method": method}
            response = self._daemon_get("/tap", params=params)
            return [TextContent(type="text", text=f"Tapped at ({x}, {y}) [strict-daemon]: {response.text}")]

        # Prefer daemon /tap first so default behavior uses real touch injection.
        params = {"x": x, "y": y}
        if isinstance(method, str) and method.strip():
            params["method"] = method
        try:
            response = self._daemon_get("/tap", params=params)
            if response.status_code != 404 and "Not Found" not in (response.text or ""):
                return [TextContent(type="text", text=f"Tapped at ({x}, {y}) [daemon]: {response.text}")]
        except Exception:
            pass

        # Prefer /touch/tap (iOSRunPortal-style) if available.
        payload = {"x": x, "y": y}
        if isinstance(method, str) and method.strip():
            payload["method"] = method
        if isinstance(pixel, bool):
            payload["pixel"] = pixel

        headers = self.client.build_auth_headers()
        try:
            response = self.client.post("/touch/tap", json=payload, headers=headers)
            data = None
            try:
                data = response.json()
            except Exception:
                data = None
            if response.status_code < 400 and isinstance(data, dict):
                if data.get("success") is True or data.get("status") == "ok":
                    return [TextContent(type="text", text=f"Tapped at ({x}, {y}): {response.text}")]
        except Exception:
            pass

        # Fallback to /tap on the active base URL.
        response = self.client.get("/tap", params=params)
        return [TextContent(type="text", text=f"Tapped at ({x}, {y}): {response.text}")]

    async def _handle_screenshot(self) -> List[TextContent]:
        """Handle device_screenshot tool."""
        file_first = await self._handle_screenshot_file_fallback(
            reason="preferred low-memory file screenshot path",
            return_image=True,
        )
        if any(isinstance(item, ImageContent) for item in file_first):
            return file_first

        try:
            response = self._daemon_get("/screenshot")
        except Exception:
            response = self.client.get("/screenshot")
        content_type = (response.headers.get("content-type") or "").lower()

        # New daemon behavior: /screenshot can return raw image/png bytes.
        if content_type.startswith("image/") and response.content:
            mime = content_type.split(";")[0].strip() or "image/png"
            payload = base64.b64encode(response.content).decode("ascii")
            return [
                TextContent(type="text", text=f"Screenshot captured ({len(response.content)} bytes binary)"),
                ImageContent(type="image", data=payload, mimeType=mime),
            ]

        try:
            data = response.json()
        except Exception:
            return [TextContent(type="text", text=f"Screenshot failed: non-JSON response ({response.text})")]

        ok = False
        if isinstance(data, dict):
            if data.get("success") is True:
                ok = True
            elif data.get("status") == "ok":
                ok = True

        if ok:
            payload = data.get("data", "")
            size = len(payload) if isinstance(payload, str) else 0
            max_b64 = int(os.environ.get("KIMIRUN_SCREENSHOT_MAX_B64", "2000000"))
            if size > max_b64:
                return await self._handle_screenshot_file_fallback(reason=f"base64 too large ({size} > {max_b64})")
            if isinstance(payload, str) and payload:
                return [
                    TextContent(type="text", text=f"Screenshot captured ({size} bytes base64)"),
                    ImageContent(type="image", data=payload, mimeType="image/png"),
                ]
            return await self._handle_screenshot_file_fallback(reason="missing base64 payload")

        err = data.get("error") if isinstance(data, dict) else None
        if not err and isinstance(data, dict):
            err = data.get("message")
        return await self._handle_screenshot_file_fallback(reason=err or "Unknown error")

    async def _handle_screenshot_file_fallback(self, reason: str, return_image: bool = False) -> List[TextContent]:
        """Fallback to /screenshot/file to avoid huge base64 payloads."""
        fmt = os.environ.get("KIMIRUN_SCREENSHOT_FILE_FORMAT", "png").lower()
        quality = os.environ.get("KIMIRUN_SCREENSHOT_FILE_QUALITY", "0.6")
        params = {"format": fmt, "quality": quality}
        try:
            response = self._daemon_get("/screenshot/file", params=params)
        except Exception:
            response = self.client.get("/screenshot/file", params=params)
        try:
            data = response.json()
        except Exception:
            return [TextContent(type="text", text=f"Screenshot fallback failed: non-JSON response ({response.text})")]

        if isinstance(data, dict) and data.get("status") == "ok":
            path = data.get("path", "")
            bytes_len = data.get("bytes", 0)
            if return_image and isinstance(path, str) and path:
                try:
                    with open(path, "rb") as f:
                        raw = f.read()
                    if raw:
                        digest = hashlib.sha1(raw).hexdigest()
                        if digest == self._last_screenshot_hash and len(raw) == self._last_screenshot_bytes:
                            self._stale_screenshot_count += 1
                        else:
                            self._stale_screenshot_count = 0
                        self._last_screenshot_hash = digest
                        self._last_screenshot_bytes = len(raw)

                        mime = "image/png"
                        out_fmt = str(data.get("format", fmt)).lower()
                        if out_fmt in {"jpg", "jpeg"}:
                            mime = "image/jpeg"
                        payload = base64.b64encode(raw).decode("ascii")
                        try:
                            os.remove(path)
                        except Exception:
                            pass
                        msg = f"Screenshot captured via file path ({len(raw)} bytes)"
                        out = [TextContent(type="text", text=msg)]
                        if self._stale_screenshot_count >= 2:
                            ui_tree = self._fetch_ui_tree()
                            if self._is_switcher_tree(ui_tree):
                                labels = self._switcher_card_labels(ui_tree)
                                label_hint = f" cards={labels}" if labels else ""
                                out.append(
                                    TextContent(
                                        type="text",
                                        text=(
                                            f"Warning: stale screenshot repeated {self._stale_screenshot_count + 1}x "
                                            f"while App Switcher is active ({label_hint.strip()}). "
                                            "Try `device_press_home` to run recovery sequence."
                                        ),
                                    )
                                )
                        out.append(ImageContent(type="image", data=payload, mimeType=mime))
                        return out
                except Exception as e:
                    return [
                        TextContent(type="text", text=f"Screenshot fallback used: {reason}"),
                        TextContent(type="text", text=f"Saved to {path} ({bytes_len} bytes, {data.get('format', '')})"),
                        TextContent(type="text", text=f"Readback failed: {type(e).__name__}: {e}"),
                    ]
            return [
                TextContent(type="text", text=f"Screenshot fallback used: {reason}"),
                TextContent(type="text", text=f"Saved to {path} ({bytes_len} bytes, {data.get('format', '')})"),
            ]

        err = data.get("error") if isinstance(data, dict) else None
        if not err and isinstance(data, dict):
            err = data.get("message")
        if isinstance(err, str) and "Proxy screenshot unavailable" in err:
            return [
                TextContent(type="text", text=f"Screenshot failed: {reason}."),
                TextContent(
                    type="text",
                    text="Daemon screenshot proxy is unavailable (no active SpringBoard/app screenshot endpoint).",
                ),
                TextContent(
                    type="text",
                    text="To restore screenshots, run a SpringBoard proxy server on port 8765 (or app proxy on 8766/8767).",
                ),
            ]
        return [TextContent(type="text", text=f"Screenshot failed: {reason}. Fallback error: {err or 'Unknown error'}")]

    async def _handle_type_text(self, arguments: dict) -> List[TextContent]:
        """Handle device_type_text tool."""
        text = arguments.get("text", "")
        try:
            response = self._daemon_get("/keyboard/type", params={"text": text})
        except Exception:
            response = self.client.get("/keyboard/type", params={"text": text})
        return [TextContent(type="text", text=f"Typed text: {response.text}")]

    async def _handle_swipe(self, arguments: dict) -> List[TextContent]:
        """Handle device_swipe tool."""
        duration_ms = arguments.get("duration", 500)
        duration = float(duration_ms) / 1000.0
        method = arguments.get("method")
        pixel = arguments.get("pixel")
        scroll = arguments.get("scroll")

        # Strict non-AX methods must go through daemon (8876) so strict verification runs centrally.
        if self._is_strict_non_ax_method(method):
            params = {
                "x1": arguments.get("startX"),
                "y1": arguments.get("startY"),
                "x2": arguments.get("endX"),
                "y2": arguments.get("endY"),
                "duration": duration,
                "method": method,
            }
            response = self._daemon_get("/swipe", params=params)
            return [TextContent(type="text", text=f"Swiped [strict-daemon]: {response.text}")]

        # Prefer daemon /swipe first so default behavior uses real swipe injection.
        params = {
            "x1": arguments.get("startX"),
            "y1": arguments.get("startY"),
            "x2": arguments.get("endX"),
            "y2": arguments.get("endY"),
            "duration": duration,
        }
        if isinstance(method, str) and method.strip():
            params["method"] = method
        try:
            response = self._daemon_get("/swipe", params=params)
            if response.status_code != 404 and "Not Found" not in (response.text or ""):
                return [TextContent(type="text", text=f"Swiped [daemon]: {response.text}")]
        except Exception:
            pass

        # Prefer /touch/swipe (iOSRunPortal-style) if available.
        payload = {
            "startX": arguments.get("startX"),
            "startY": arguments.get("startY"),
            "endX": arguments.get("endX"),
            "endY": arguments.get("endY"),
            "duration": duration,
        }
        if isinstance(method, str) and method.strip():
            payload["method"] = method
        if isinstance(pixel, bool):
            payload["pixel"] = pixel
        if isinstance(scroll, bool):
            payload["scroll"] = scroll

        headers = self.client.build_auth_headers()
        try:
            response = self.client.post("/touch/swipe", json=payload, headers=headers)
            data = None
            try:
                data = response.json()
            except Exception:
                data = None
            if response.status_code < 400 and isinstance(data, dict):
                if data.get("success") is True or data.get("status") == "ok":
                    return [TextContent(type="text", text=f"Swiped: {response.text}")]
        except Exception:
            pass

        # Fallback to /swipe on the active base URL.
        response = self.client.get("/swipe", params=params)
        return [TextContent(type="text", text=f"Swiped: {response.text}")]

    async def _handle_open_app_switcher(self) -> List[TextContent]:
        """Handle device_open_app_switcher tool."""
        try:
            response = self._daemon_get("/app/switcher")
            if response.status_code < 400 and "Not Found" not in (response.text or ""):
                return [TextContent(type="text", text=f"App switcher opened [daemon]: {response.text}")]
        except Exception:
            pass

        # Backward-compatible fallback for older daemon builds where /home mapped to app switcher.
        try:
            response = self._daemon_get("/home")
            if response.status_code < 400 and "Not Found" not in (response.text or ""):
                return [TextContent(type="text", text=f"App switcher opened [legacy /home]: {response.text}")]
        except Exception:
            pass

        return [TextContent(type="text", text="Open app switcher failed: daemon endpoint unavailable")]

    async def _handle_press_home(self) -> List[TextContent]:
        """Handle device_press_home tool."""
        out: List[TextContent] = []

        try:
            response = self._daemon_get("/home")
            if response.status_code < 400 and "Not Found" not in (response.text or ""):
                payload = self._json_or_none(response)
                mode = ""
                if isinstance(payload, dict):
                    mode = str(payload.get("mode", "")).strip().lower()
                if mode == "app_switcher":
                    out.append(
                        TextContent(
                            type="text",
                            text=(
                                "Home endpoint returned app_switcher mode; "
                                "falling back to explicit home gesture."
                            ),
                        )
                    )
                else:
                    out.append(TextContent(type="text", text=f"Home pressed [daemon]: {response.text}"))
                    return out
        except Exception:
            pass

        width, height = self._screen_dimensions()
        x = max(10, int(width * 0.5))
        y_start = max(10, int(height * 0.97))
        y_end = max(10, int(height * 0.70))
        params = {"x1": x, "y1": y_start, "x2": x, "y2": y_end, "duration": 0.22}

        try:
            response = self._daemon_get("/swipe", params=params)
            out.append(TextContent(type="text", text=f"Home gesture [daemon swipe]: {response.text}"))
        except Exception:
            try:
                response = self.client.get("/swipe", params=params)
                out.append(TextContent(type="text", text=f"Home gesture [fallback swipe]: {response.text}"))
            except Exception as e:
                return [TextContent(type="text", text=f"Home action failed: {type(e).__name__}: {e}")]

        ui_tree = self._fetch_ui_tree()
        if self._is_switcher_tree(ui_tree):
            labels = self._switcher_card_labels(ui_tree)
            label_hint = f" cards={labels}" if labels else ""
            out.append(
                TextContent(
                    type="text",
                    text=f"Switcher still active after home gesture ({label_hint.strip()}). Running recovery taps/swipes.",
                )
            )
            recovered, note = self._recover_from_switcher(width=width, height=height)
            out.append(
                TextContent(
                    type="text",
                    text=f"Switcher recovery: {'recovered' if recovered else 'not recovered'} ({note})",
                )
            )

        return out

    async def _handle_launch_app(self, arguments: dict) -> List[TextContent]:
        """Handle device_launch_app tool."""
        bundle_id = arguments.get("bundle_id", "")
        try:
            response = self._daemon_get("/app/launch", params={"bundleID": bundle_id})
        except Exception:
            response = self.client.get("/app/launch", params={"bundleID": bundle_id})
        if response.status_code >= 400 or "Not Found" in (response.text or ""):
            response = self.client.get("/app/launch", params={"bundleID": bundle_id})
        return [TextContent(type="text", text=f"Launch app '{bundle_id}': {response.text}")]

    async def _handle_ui_hierarchy(self) -> List[TextContent]:
        """Handle device_get_ui_hierarchy tool."""
        try:
            response = self._daemon_get("/uiHierarchy")
            data = self._json_or_none(response)
        except Exception:
            response = self.client.get("/uiHierarchy")
            data = self._json_or_none(response)
        if (response.status_code >= 400) or (not isinstance(data, dict)) or (not data.get("success")):
            response = self.client.get("/uiHierarchy")
            data = self._json_or_none(response)
        if not isinstance(data, dict):
            return [TextContent(type="text", text="UI hierarchy failed: Invalid JSON response")]
        if data.get("success"):
            tree = data.get("data", {}) if isinstance(data.get("data"), dict) else {}
            hierarchy = json.dumps(tree, indent=2)
            out = [TextContent(type="text", text=f"UI Hierarchy:\n{hierarchy}")]
            if self._is_switcher_tree(tree):
                labels = self._switcher_card_labels(tree)
                label_hint = f" cards={labels}" if labels else ""
                out.append(
                    TextContent(
                        type="text",
                        text=(
                            f"Warning: App Switcher is foreground ({label_hint.strip()}). "
                            "Capture and touch may target snapshot cards instead of a live app."
                        ),
                    )
                )
            return out
        return [TextContent(type="text", text=f"UI hierarchy failed: {data.get('error', 'Unknown error')}")]

    async def _handle_list_apps(self, arguments: dict) -> List[TextContent]:
        """Handle device_list_apps tool."""
        system_apps = arguments.get("system_apps", False)
        params = {"systemApps": "true" if system_apps else "false"}
        try:
            response = self._daemon_get("/apps", params=params)
            data = self._json_or_none(response)
        except Exception:
            response = self.client.get("/apps", params=params)
            data = self._json_or_none(response)
        if (response.status_code >= 400) or (not isinstance(data, dict)) or (not data.get("success")):
            try:
                response = self._daemon_get("/apps", params=params)
                data = self._json_or_none(response)
            except Exception:
                response = self.client.get("/apps", params=params)
                data = self._json_or_none(response)
        if (response.status_code >= 400) or (not isinstance(data, dict)) or (not data.get("success")):
            response = self.client.get("/apps", params=params)
            data = self._json_or_none(response)
        if not isinstance(data, dict):
            return [TextContent(type="text", text="List apps failed: Invalid JSON response")]
        if data.get("success"):
            apps = json.dumps(data.get("data", []), indent=2)
            return [TextContent(type="text", text=f"Installed apps:\n{apps}")]
        return [TextContent(type="text", text=f"List apps failed: {data.get('error', 'Unknown error')}")]

    async def _handle_screen_size(self) -> List[TextContent]:
        """Handle device_get_screen_size tool."""
        response = self.client.get("/screen")
        data = self._json_or_none(response)
        if (response.status_code >= 400) or (not isinstance(data, dict)) or (not data.get("success")):
            response = self._daemon_get("/screen")
            data = self._json_or_none(response)
        if not isinstance(data, dict):
            return [TextContent(type="text", text="Get screen size failed: Invalid JSON response")]
        if data.get("success"):
            size_info = json.dumps(data.get("data", {}), indent=2)
            return [TextContent(type="text", text=f"Screen size:\n{size_info}")]
        return [TextContent(type="text", text=f"Get screen size failed: {data.get('error', 'Unknown error')}")]
