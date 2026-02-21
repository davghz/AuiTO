"""Shared registry helper methods."""

import time
from typing import List


class DeviceCommonMixin:
    def _screen_dimensions(self) -> tuple[int, int]:
        width, height = 375, 812
        try:
            response = self.client.get("/screen")
            data = self._json_or_none(response)
            if isinstance(data, dict) and data.get("success"):
                payload = data.get("data", {}) or {}
                width = int(payload.get("width", width))
                height = int(payload.get("height", height))
                return width, height
        except Exception:
            pass

        try:
            response = self._daemon_get("/screen")
            data = self._json_or_none(response)
            if isinstance(data, dict) and data.get("success"):
                payload = data.get("data", {}) or {}
                width = int(payload.get("width", width))
                height = int(payload.get("height", height))
        except Exception:
            pass

        return width, height

    def _fetch_ui_tree(self) -> dict:
        """Best-effort UI tree fetch for health checks/recovery decisions."""
        try:
            response = self.client.get("/uiHierarchy")
            data = self._json_or_none(response)
            if isinstance(data, dict) and data.get("success") and isinstance(data.get("data"), dict):
                return data.get("data", {})
        except Exception:
            pass

        try:
            response = self._daemon_get("/uiHierarchy")
            data = self._json_or_none(response)
            if isinstance(data, dict) and data.get("success") and isinstance(data.get("data"), dict):
                return data.get("data", {})
        except Exception:
            pass

        return {}

    def _tree_nodes(self, node):
        if isinstance(node, dict):
            yield node
            children = node.get("children")
            if isinstance(children, list):
                for child in children:
                    yield from self._tree_nodes(child)
        elif isinstance(node, list):
            for child in node:
                yield from self._tree_nodes(child)

    def _is_switcher_tree(self, tree: dict) -> bool:
        if not isinstance(tree, dict):
            return False
        for node in self._tree_nodes(tree):
            class_name = str(node.get("className", ""))
            identifier = str(node.get("identifier", ""))
            if class_name in {"SBMainSwitcherWindow", "SBFluidSwitcherContentView"}:
                return True
            if identifier in {"SBSwitcherWindow", "AppSwitcherContentView"}:
                return True
        return False

    def _switcher_card_labels(self, tree: dict) -> List[str]:
        labels: List[str] = []
        if not isinstance(tree, dict):
            return labels
        for node in self._tree_nodes(tree):
            class_name = str(node.get("className", ""))
            label = str(node.get("label", "")).strip()
            if class_name == "SBReusableSnapshotItemContainer" and label and label not in labels:
                labels.append(label)
        return labels[:6]

    def _best_effort_get(self, path: str, params: dict) -> None:
        try:
            self._daemon_get(path, params=params)
            return
        except Exception:
            pass
        try:
            self.client.get(path, params=params)
        except Exception:
            pass

    def _recover_from_switcher(self, width: int, height: int) -> tuple[bool, str]:
        """
        Best-effort exit sequence for iOS app switcher.
        Returns (recovered, note).
        """
        cx = max(10, int(width * 0.5))
        cy = max(10, int(height * 0.5))
        y_bottom = max(10, int(height * 0.97))
        y_short = max(10, int(height * 0.86))
        y_lower_tap = max(10, int(height * 0.88))

        # 1) Tap focused card center (open app from switcher)
        self._best_effort_get("/tap", {"x": cx, "y": cy, "method": "ax"})
        time.sleep(0.12)
        if not self._is_switcher_tree(self._fetch_ui_tree()):
            return True, "card-center tap"

        # 2) Short home swipe (dismiss switcher to home on gesture devices)
        self._best_effort_get("/swipe", {"x1": cx, "y1": y_bottom, "x2": cx, "y2": y_short, "duration": 0.14})
        time.sleep(0.12)
        if not self._is_switcher_tree(self._fetch_ui_tree()):
            return True, "short home swipe"

        # 3) Bottom-area tap fallback
        self._best_effort_get("/tap", {"x": cx, "y": y_lower_tap, "method": "ax"})
        time.sleep(0.12)
        if not self._is_switcher_tree(self._fetch_ui_tree()):
            return True, "bottom-area tap"

        return False, "all switcher-exit gestures failed"
