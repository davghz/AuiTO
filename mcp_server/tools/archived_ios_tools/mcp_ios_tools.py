"""
MCP Server Tools for iOS Touch Injection
Registers AI-powered tools with the MCP server
"""

import asyncio
import json
from typing import Dict, Any, Optional, List
from datetime import datetime

from mcp.types import Tool, TextContent

from .model_clients import get_ensemble


class IOSMcpTools:
    """MCP tool definitions for iOS automation with AI research capabilities"""
    
    def __init__(self):
        self.research_history = []
    
    def get_tool_definitions(self) -> List[Tool]:
        """Get all tool definitions for MCP registration"""
        return [
            Tool(
                name="ios_research_touch_injection",
                description="Research iOS touch injection methods using multiple AI models",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "ios_version": {
                            "type": "string",
                            "description": "iOS version (e.g., 13.2.3)",
                            "default": "13.2.3"
                        },
                        "device": {
                            "type": "string",
                            "description": "Device model (e.g., iPhone X)",
                            "default": "iPhone X"
                        },
                        "specific_issue": {
                            "type": "string",
                            "description": "Specific issue to research",
                            "enum": [
                                "general_methods",
                                "iohid_structure",
                                "alternatives",
                                "zxtouch_analysis",
                                "entitlements"
                            ],
                            "default": "general_methods"
                        }
                    }
                }
            ),
            Tool(
                name="ios_analyze_error",
                description="Analyze touch injection failure with AI models",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "error_description": {
                            "type": "string",
                            "description": "Description of what happened (or didn't happen)"
                        },
                        "method_used": {
                            "type": "string",
                            "description": "Touch injection method attempted",
                            "enum": ["iohid", "backboard", "accessibility", "socket"]
                        },
                        "context": {
                            "type": "object",
                            "description": "Additional context about the attempt",
                            "properties": {
                                "process_name": {"type": "string"},
                                "thread": {"type": "string"},
                                "coordinates": {"type": "string"}
                            }
                        }
                    },
                    "required": ["error_description", "method_used"]
                }
            ),
            Tool(
                name="ios_suggest_fix",
                description="Get AI suggestions for fixing touch injection issues",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "current_code": {
                            "type": "string",
                            "description": "Current implementation code"
                        },
                        "symptoms": {
                            "type": "string",
                            "description": "What the code is doing (or not doing)"
                        }
                    },
                    "required": ["current_code", "symptoms"]
                }
            ),
            Tool(
                name="ios_test_coordinates",
                description="Get normalized coordinates for common UI elements on iPhone X",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "element": {
                            "type": "string",
                            "description": "UI element to get coordinates for",
                            "enum": [
                                "home_button",
                                "control_center",
                                "notification_center",
                                "dock",
                                "status_bar",
                                "screen_center"
                            ]
                        }
                    },
                    "required": ["element"]
                }
            ),
            Tool(
                name="ios_generate_event_sequence",
                description="Generate correct IOHIDEvent sequence for touch action",
                inputSchema={
                    "type": "object",
                    "properties": {
                        "action": {
                            "type": "string",
                            "description": "Touch action type",
                            "enum": ["tap", "long_press", "swipe", "drag", "pinch"]
                        },
                        "parameters": {
                            "type": "object",
                            "description": "Action-specific parameters"
                        }
                    },
                    "required": ["action"]
                }
            )
        ]
    
    async def handle_tool_call(self, tool_name: str, params: Dict[str, Any]) -> List[TextContent]:
        """Handle MCP tool calls"""
        
        if tool_name == "ios_research_touch_injection":
            return await self._handle_research(params)
        elif tool_name == "ios_analyze_error":
            return await self._handle_error_analysis(params)
        elif tool_name == "ios_suggest_fix":
            return await self._handle_suggest_fix(params)
        elif tool_name == "ios_test_coordinates":
            return await self._handle_coordinates(params)
        elif tool_name == "ios_generate_event_sequence":
            return await self._handle_event_sequence(params)
        else:
            return [TextContent(type="text", text=f"Unknown tool: {tool_name}")]
    
    async def _handle_research(self, params: Dict[str, Any]) -> List[TextContent]:
        """Handle ios_research_touch_injection tool"""
        ios_version = params.get("ios_version", "13.2.3")
        device = params.get("device", "iPhone X")
        issue = params.get("specific_issue", "general_methods")
        
        prompts = {
            "general_methods": f"""Research iOS touch injection for version {ios_version} on {device}.

The current implementation uses IOHIDEventCreateDigitizerEvent with proper iOS 13 setup:
- IOHIDEventSystemClientCreateSimpleClient
- IOHIDEventSystemClientSetDispatchQueue (main queue)  
- IOHIDEventSystemClientActivate
- Sender ID 0xDEFACEDBEEFFECE5

Events are created and dispatched without errors, but don't register on the UI.
The tweak runs inside SpringBoard process (MobileSubstrate) on checkra1n jailbreak.

Please research and provide:
1. iOS {ios_version} specific HID system changes
2. Why events might dispatch but not register
3. Alternative methods specific to {ios_version}
4. Any daemon vs SpringBoard differences
5. Working solutions with code examples

Focus on practical solutions for this specific setup.""",

            "iohid_structure": """Analyze the exact IOHIDEvent structure needed for iOS 13.2.3.

Current implementation uses:
- kIOHIDDigitizerTransducerTypeHand (3) for parent
- HAND event with Range|Touch|Position mask for down
- FINGER event with same mask
- Normalized coordinates 0-1
- Sender ID 0xDEFACEDBEEFFECE5

But touches don't register. What could be wrong?

Please provide:
1. Correct event structure for iOS 13.2.3
2. Required vs optional fields
3. Proper timestamp format
4. Any special handling needed

Include exact code that works.""",

            "alternatives": f"""List all working touch injection alternatives for iOS {ios_version}.

Already tried (not working):
1. IOHIDEvent with IOHIDEventSystemClient
2. BKSHIDEventDeliveryManager
3. AXEventRepresentation

What else exists?
- GSEvent from GraphicsServices?
- IOMobileFramebuffer?
- backboardd mach port?
- IOSurface injection?

For each method:
1. Does it work on iOS {ios_version}?
2. Implementation approach
3. Required permissions/entitlements
4. Pros and cons

Focus on proven solutions.""",

            "zxtouch_analysis": """Analyze ZXTouch's approach for iOS 13 touch injection.

ZXTouch (IOS13-SimulateTouch) works on iOS 13-14 without SpringBoard hook.
It runs as a daemon and communicates via socket.

Questions:
1. How does it inject touches without SpringBoard?
2. What mechanism does it use?
3. Can this approach be used in a SpringBoard tweak?
4. What are the key differences?

Provide the core implementation details and any transferable insights.""",

            "entitlements": """List all entitlements that might affect touch injection on iOS 13.2.3.

Context:
- Running on checkra1n jailbreak
- AMFI bypassed with amfi_get_out_of_my_way=1
- Tweak runs in SpringBoard

Questions:
1. What entitlements does IOHIDEventSystemClient need?
2. What entitlements does BackBoardServices need?
3. Which are enforced vs bypassed on checkra1n?
4. Can we add entitlements to the dylib?
5. Any other permission requirements?

Provide specific entitlement keys and their purposes."""
        }
        
        prompt = prompts.get(issue, prompts["general_methods"])
        
        system_prompt = """You are an expert iOS reverse engineer and jailbreak developer.
You have deep knowledge of iOS private APIs, HID events, and touch injection.
Provide accurate, technical information with code examples.
Be honest about what you don't know."""
        
        ensemble = get_ensemble()
        response = await ensemble.generate_consensus(prompt, system_prompt)
        
        # Record research
        self.research_history.append({
            "timestamp": datetime.now().isoformat(),
            "issue": issue,
            "ios_version": ios_version,
            "device": device
        })
        
        return [TextContent(type="text", text=response)]
    
    async def _handle_error_analysis(self, params: Dict[str, Any]) -> List[TextContent]:
        """Handle ios_analyze_error tool"""
        error_desc = params.get("error_description", "")
        method = params.get("method_used", "")
        context = params.get("context", {})
        
        prompt = f"""Analyze this iOS touch injection failure:

METHOD: {method}
ERROR DESCRIPTION: {error_desc}
CONTEXT: {json.dumps(context, indent=2)}

The code executes without errors (no crashes, returns success), but touches don't register on the UI.

Please analyze:
1. What could cause silent failure in {method}?
2. Are there any missing setup steps?
3. Threading or queue issues?
4. iOS 13.2.3 specific issues?
5. Suggested fixes or workarounds

Be specific and technical."""
        
        system_prompt = "You are an expert iOS debugging specialist. Analyze the issue and provide actionable fixes."
        
        ensemble = get_ensemble()
        response = await ensemble.generate_consensus(prompt, system_prompt)
        
        return [TextContent(type="text", text=response)]
    
    async def _handle_suggest_fix(self, params: Dict[str, Any]) -> List[TextContent]:
        """Handle ios_suggest_fix tool"""
        code = params.get("current_code", "")
        symptoms = params.get("symptoms", "")
        
        prompt = f"""Review this iOS touch injection code and suggest fixes.

SYMPTOMS: {symptoms}

CURRENT CODE:
```objc
{code}
```

Please provide:
1. Analysis of what might be wrong
2. Specific fixes with code changes
3. Alternative approaches if this method won't work
4. iOS 13.2.3 specific considerations

Make your suggestions concrete and implementable."""
        
        system_prompt = "You are an expert Objective-C and iOS developer. Review code and provide concrete fixes."
        
        ensemble = get_ensemble()
        response = await ensemble.generate_consensus(prompt, system_prompt)
        
        return [TextContent(type="text", text=response)]
    
    async def _handle_coordinates(self, params: Dict[str, Any]) -> List[TextContent]:
        """Handle ios_test_coordinates tool"""
        element = params.get("element", "")
        
        # iPhone X coordinates (normalized 0-1)
        coordinates = {
            "home_button": {"x": 0.5, "y": 0.92, "note": "Home indicator area"},
            "control_center": {"x": 0.5, "y": 0.05, "note": "Swipe down from top-right"},
            "notification_center": {"x": 0.25, "y": 0.05, "note": "Swipe down from top-left"},
            "dock": {"x": 0.5, "y": 0.88, "note": "Dock area at bottom"},
            "status_bar": {"x": 0.5, "y": 0.03, "note": "Status bar area"},
            "screen_center": {"x": 0.5, "y": 0.5, "note": "Center of screen"}
        }
        
        coord = coordinates.get(element, {"x": 0.5, "y": 0.5})
        
        text = (f"Element: {element}\n"
                f"Normalized: x={coord['x']}, y={coord['y']}\n"
                f"Absolute (1125×2436): x={coord['x']*1125:.0f}, y={coord['y']*2436:.0f}\n"
                f"Note: {coord.get('note', '')}")
        
        return [TextContent(type="text", text=text)]
    
    async def _handle_event_sequence(self, params: Dict[str, Any]) -> List[TextContent]:
        """Handle ios_generate_event_sequence tool"""
        action = params.get("action", "tap")
        parameters = params.get("parameters", {})
        
        sequences = {
            "tap": """// Single tap event sequence for iOS 13.2.3
// DOWN event
IOHIDEventRef handDown = IOHIDEventCreateDigitizerEvent(
    allocator, timestamp,
    kIOHIDDigitizerTransducerTypeHand,
    0, 0,
    kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventPosition,
    0, normX, normY, 0.0f,
    1.0f, 0.0f, YES, YES, 0
);

IOHIDEventRef fingerDown = IOHIDEventCreateDigitizerFingerEvent(
    allocator, timestamp,
    1, 2,
    kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventPosition,
    normX, normY, 0.0f,
    1.0f, 0.0f, YES, YES, 0
);

IOHIDEventAppendEvent(handDown, fingerDown, false);
IOHIDEventSetSenderID(handDown, 0xDEFACEDBEEFFECE5ULL);

// Dispatch DOWN
IOHIDEventSystemClientDispatchEvent(client, handDown);

// Small delay
[NSThread sleepForTimeInterval:0.05];

// UP event  
IOHIDEventRef handUp = IOHIDEventCreateDigitizerEvent(
    allocator, timestamp + 0.05,
    kIOHIDDigitizerTransducerTypeHand,
    0, 0,
    kIOHIDDigitizerEventPosition | kIOHIDDigitizerEventTouch,
    0, normX, normY, 0.0f,
    0.0f, 0.0f, NO, NO, 0
);

IOHIDEventRef fingerUp = IOHIDEventCreateDigitizerFingerEvent(
    allocator, timestamp + 0.05,
    1, 2,
    kIOHIDDigitizerEventPosition | kIOHIDDigitizerEventTouch,
    normX, normY, 0.0f,
    0.0f, 0.0f, NO, NO, 0
);

IOHIDEventAppendEvent(handUp, fingerUp, false);
IOHIDEventSetSenderID(handUp, 0xDEFACEDBEEFFECE5ULL);

// Dispatch UP
IOHIDEventSystemClientDispatchEvent(client, handUp);
""",
            "long_press": """// Long press event sequence
// Similar to tap but with 0.5-1.0s delay between DOWN and UP
// Can add kIOHIDDigitizerEventCancel if cancelled
""",
            "swipe": """// Swipe event sequence
// Multiple MOVE events between DOWN and UP
// Update x,y coordinates for each MOVE
// kIOHIDDigitizerEventPosition mask for moves
"""
        }
        
        sequence = sequences.get(action, sequences["tap"])
        text = f"Event sequence for {action}:\n\n```objc\n{sequence}\n```"
        
        return [TextContent(type="text", text=text)]


# Singleton instance
_ios_tools = None

def get_ios_mcp_tools() -> IOSMcpTools:
    global _ios_tools
    if _ios_tools is None:
        _ios_tools = IOSMcpTools()
    return _ios_tools