#!/usr/bin/env python3
"""
Test script for multi-model AI tools
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))


def test_imports():
    """Test that all modules can be imported"""
    print("Testing imports...")
    
    try:
        from tools import (
            get_ensemble,
            get_orchestrator,
            get_ios_mcp_tools,
            IOSReverseEngineer
        )
        print("✅ All imports successful")
        return True
    except ImportError as e:
        print(f"❌ Import error: {e}")
        import traceback
        traceback.print_exc()
        return False


def test_model_clients():
    """Test model client initialization"""
    print("\nTesting model clients...")
    
    try:
        from tools import get_ensemble
        
        ensemble = get_ensemble()
        print(f"✅ Ensemble initialized with {len(ensemble.clients)} clients")
        
        # Check which clients have API keys
        for name, client in ensemble.clients.items():
            status = "✅ has key" if client.api_key else "❌ no key"
            print(f"   {name}: {status}")
        
        return True
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        return False


def test_orchestrator():
    """Test orchestrator initialization"""
    print("\nTesting orchestrator...")
    
    try:
        from tools import get_orchestrator
        
        orch = get_orchestrator()
        print(f"✅ Orchestrator initialized")
        print(f"   Analysis history: {len(orch.analysis_history)} entries")
        
        return True
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        return False


def test_mcp_tools():
    """Test MCP tools initialization"""
    print("\nTesting MCP tools...")
    
    try:
        from tools import get_ios_mcp_tools
        
        tools = get_ios_mcp_tools()
        definitions = tools.get_tool_definitions()
        
        print(f"✅ MCP tools initialized")
        print(f"   Available tools: {len(definitions)}")
        
        for tool in definitions:
            print(f"   - {tool.name}")
        
        return True
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        return False


def test_researcher():
    """Test researcher initialization"""
    print("\nTesting researcher...")
    
    try:
        from tools import IOSReverseEngineer
        
        researcher = IOSReverseEngineer()
        print(f"✅ Researcher initialized")
        
        return True
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        return False


def main():
    """Run all tests"""
    print("=" * 60)
    print("Multi-Model AI Tools - Test Suite")
    print("=" * 60)
    
    results = []
    
    results.append(("Imports", test_imports()))
    results.append(("Model Clients", test_model_clients()))
    results.append(("Orchestrator", test_orchestrator()))
    results.append(("MCP Tools", test_mcp_tools()))
    results.append(("Researcher", test_researcher()))
    
    print("\n" + "=" * 60)
    print("TEST SUMMARY")
    print("=" * 60)
    
    for name, passed in results:
        status = "✅ PASS" if passed else "❌ FAIL"
        print(f"{status}: {name}")
    
    all_passed = all(r[1] for r in results)
    
    print("\n" + ("✅ All tests passed!" if all_passed else "❌ Some tests failed"))
    
    return 0 if all_passed else 1


if __name__ == "__main__":
    sys.exit(main())