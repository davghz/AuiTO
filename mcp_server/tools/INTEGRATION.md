# Multi-Model AI Tools for iOS Touch Injection

A coordinated system of AI models working together to solve iOS touch injection problems.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     MCP Server (iOS)                            │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              Multi-Model AI Tools                        │   │
│  │                                                          │   │
│  │  ┌─────────┐ ┌───────────┐ ┌─────────┐ ┌────────────┐   │   │
│  │  │  Arcee  │ │ DeepSeek  │ │  Qwen   │ │  Claude    │   │   │
│  │  │ Trinity │ │   R1      │ │  Coder  │ │  Opus 4.5  │   │   │
│  │  └────┬────┘ └─────┬─────┘ └────┬────┘ └─────┬──────┘   │   │
│  │       └─────────────┴─────────────┴────────────┘          │   │
│  │                      │                                    │   │
│  │              ┌───────▼────────┐                          │   │
│  │              │   Ensemble     │                          │   │
│  │              │  (Aggregates)  │                          │   │
│  │              └───────┬────────┘                          │   │
│  │                      │                                    │   │
│  │              ┌───────▼────────┐                          │   │
│  │              │ Orchestrator   │                          │   │
│  │              │ (4-Phase Flow) │                          │   │
│  │              └───────┬────────┘                          │   │
│  │                      │                                    │   │
│  │         ┌────────────┼────────────┐                      │   │
│  │         ▼            ▼            ▼                      │   │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐                 │   │
│  │  │ Research │ │ Analyze  │ │ Suggest  │                 │   │
│  │  │   Tools  │ │  Tools   │ │   Fixes  │                 │   │
│  │  └──────────┘ └──────────┘ └──────────┘                 │   │
│  │                                                          │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
└──────────────────────────────┼──────────────────────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │  MCP Tool Calls     │
                    └─────────────────────┘
```

## Supported Models

| Model | Provider | Purpose |
|-------|----------|---------|
| trinity-large-preview | Arcee AI | Code analysis & generation |
| deepseek-r1-0528 | DeepSeek | Reasoning & problem solving |
| qwen3-coder | Qwen | Code-specific tasks |
| claude-opus-4.5 | Anthropic | Complex analysis & synthesis |

## 4-Phase Orchestration

### Phase 1: Problem Analysis
All models independently analyze the problem and provide:
- Root cause hypotheses
- Confidence ratings
- Key insights
- Potential issues

### Phase 2: Solution Generation
Each model generates a complete solution with:
- Full implementation code
- Pros/cons analysis
- Success chance estimate

### Phase 3: Cross-Validation
Models critique each other's solutions:
- Bug identification
- iOS 13.2.3 compatibility check
- Aggregated viability ratings

### Phase 4: Final Synthesis
Best elements combined into final recommendation:
- Optimized implementation
- Production-ready code
- Confidence score

## Setup

### 1. Install Dependencies

```bash
pip install aiohttp requests
```

### 2. Configure API Keys

Set environment variables:

```bash
export ARCEE_API_KEY="your-arcee-key"
export DEEPSEEK_API_KEY="your-deepseek-key"
export ANTHROPIC_API_KEY="your-anthropic-key"
# Qwen can use OpenRouter fallback
export OPENROUTER_API_KEY="your-openrouter-key"
```

Or create `.env` file in project root.

### 3. Test Installation

```bash
python3 tools/test_tools.py
```

## Usage

### Full Analysis

```bash
python3 tools/run_analysis.py
```

Runs complete 4-phase analysis across all models.

### Specific Research

```bash
# Research touch injection methods
python3 tools/run_analysis.py --research touch

# Analyze IOHIDEvent structure
python3 tools/run_analysis.py --research structure

# Find alternative methods
python3 tools/run_analysis.py --research alternatives

# Analyze ZXTouch approach
python3 tools/run_analysis.py --research zxtouch
```

### Quick Query

```bash
python3 tools/run_analysis.py --query "How does IOSurface injection work?"
```

### Programmatic Usage

```python
from tools import get_orchestrator, get_ios_mcp_tools

# Run full analysis
orchestrator = get_orchestrator()
result = await orchestrator.run_full_analysis({
    "ios_version": "13.2.3",
    "device": "iPhone X",
    "symptoms": "Events dispatch but don't register"
})

# Access final code
final_code = result["phases"]["final_synthesis"]["final_code"]

# Use MCP tools
tools = get_ios_mcp_tools()
definitions = tools.get_tool_definitions()
response = await tools.handle_tool_call("ios_research_touch_injection", {
    "ios_version": "13.2.3",
    "specific_issue": "iohid_structure"
})
```

## MCP Tool Registry

Tools automatically registered with MCP server:

### `ios_research_touch_injection`
Research iOS touch injection with AI models.

### `ios_analyze_error`
Analyze touch injection failures with multi-model input.

### `ios_suggest_fix`
Get AI suggestions for fixing implementation issues.

### `ios_test_coordinates`
Get test coordinates for iPhone X UI elements.

### `ios_generate_event_sequence`
Generate correct IOHIDEvent sequences for touch actions.

## Output

Results saved to `analysis_results/analysis_<timestamp>.json`:

```json
{
  "timestamp": "2026-02-03T00:21:25",
  "context": {...},
  "phases": {
    "problem_analysis": {...},
    "solution_generation": {...},
    "cross_validation": {...},
    "final_synthesis": {
      "final_code": "...",
      "success_confidence": 8
    }
  }
}
```

## Extending the System

### Adding New Models

```python
from tools.model_clients import BaseModelClient

class NewModelClient(BaseModelClient):
    MODEL = "vendor/model-name"
    
    def get_env_key(self) -> str:
        return "NEWMODEL_API_KEY"
    
    def get_default_url(self) -> str:
        return "https://api.vendor.com/v1"
    
    async def generate(self, prompt, system_prompt=None, ...):
        # Implementation
        return ModelResponse(...)
```

### Adding New Tools

```python
from tools.mcp_ios_tools import IOSMcpTools

class ExtendedTools(IOSMcpTools):
    def get_tool_definitions(self):
        defs = super().get_tool_definitions()
        defs.append({
            "name": "ios_new_tool",
            "description": "...",
            "inputSchema": {...}
        })
        return defs
```

## Integration with Existing MCP Server

Add to `mcp_server/server.py`:

```python
from tools import get_ios_mcp_tools

class IOSMcpServer:
    def __init__(self):
        self.ios_tools = get_ios_mcp_tools()
    
    async def _register_tools(self):
        tools = self.ios_tools.get_tool_definitions()
        for tool in tools:
            await self.session.register_tool(tool)
    
    async def _handle_tool_call(self, name, params):
        if name.startswith("ios_"):
            return await self.ios_tools.handle_tool_call(name, params)
        # ... existing handling
```

## Troubleshooting

### No API Keys
- Check environment variables are set
- Verify key validity with curl/API test
- Use OpenRouter as fallback for some models

### Rate Limits
- Models queried in parallel, respect rate limits
- Add delays between calls if needed
- Cache results for repeated queries

### Timeout Issues
- Increase timeout in model clients
- Use synchronous fallback (requests library)
- Retry failed requests

## License

Part of KimiRun project - iOS touch injection research.