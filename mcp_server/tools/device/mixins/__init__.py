"""Device tool registry mixins."""

from .common import DeviceCommonMixin
from .core_handlers import DeviceCoreHandlersMixin
from .a11y_handlers import DeviceA11yHandlersMixin
from .touch_handlers import DeviceTouchHandlersMixin

__all__ = [
    "DeviceCommonMixin",
    "DeviceCoreHandlersMixin",
    "DeviceA11yHandlersMixin",
    "DeviceTouchHandlersMixin",
]
