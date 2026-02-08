#!/usr/bin/env python3
"""
Multi-Model AI Analysis CLI for iOS Touch Injection

Run comprehensive analysis across multiple AI models to find working solutions.
"""

import asyncio
import json
import sys
import os
from pathlib import Path

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from tools import get_orchestrator, get_ensemble, IOSReverseEngineer


async def run_touch_injection_analysis():
    """Run full touch injection analysis"""
    
    print("""
╔══════════════════════════════════════════════════════════════════╗
║     iOS Touch Injection - Multi-Model AI Analysis System         ║
║                                                                  ║
║     Models: Arcee • DeepSeek • Qwen • Claude                     ║
╚══════════════════════════════════════════════════════════════════╝
""")
    
    # Check API keys
    required_keys = ["ARCEE_API_KEY", "DEEPSEEK_API_KEY", "ANTHROPIC_API_KEY"]
    missing = [k for k in required_keys if not os.environ.get(k)]
    
    if missing:
        print("⚠️  Missing API keys:")
        for key in missing:
            print(f"   - {key}")
        print("\nSome models may not be available.")
        print("Set API keys as environment variables or in .env file")
        print()
    
    # Initialize orchestrator
    orchestrator = get_orchestrator()
    
    # Context for the problem
    context = {
        "ios_version": "13.2.3",
        "device": "iPhone X",
        "jailbreak": "checkra1n",
        "process": "SpringBoard (MobileSubstrate tweak)",
        "symptoms": """
- IOHIDEventCreateDigitizerEvent with proper iOS 13 setup
- Events dispatch without errors (return void, no crashes)
- No error messages in syslog
- Touch simply doesn't register on UI
- Running on main thread
- Sender ID set to 0xDEFACEDBEEFFECE5
- Same code works in other implementations (ZXTouch, iOSRunPortal)
- iOSRunPortal CLI also fails on this specific device
        """
    }
    
    print(f"Context: iOS {context['ios_version']} on {context['device']}")
    print(f"Jailbreak: {context['jailbreak']}")
    print()
    
    try:
        # Run full analysis
        result = await orchestrator.run_full_analysis(context)
        
        # Save results
        output_dir = Path(__file__).parent.parent / "analysis_results"
        output_dir.mkdir(exist_ok=True)
        
        timestamp = result["timestamp"].replace(":", "-").replace(".", "-")
        output_file = output_dir / f"analysis_{timestamp}.json"
        
        with open(output_file, 'w') as f:
            json.dump(result, f, indent=2)
        
        # Print summary
        final = result["phases"]["final_synthesis"]
        
        print("\n" + "=" * 70)
        print("ANALYSIS COMPLETE")
        print("=" * 70)
        print(f"\n📊 Success Confidence: {final['success_confidence']}/10")
        print(f"🎯 Recommended Approach: {final['recommended_candidate']}")
        print(f"💾 Results saved to: {output_file}")
        
        print("\n" + "=" * 70)
        print("FINAL RECOMMENDED CODE")
        print("=" * 70)
        print(final['final_code'])
        
        print("\n" + "=" * 70)
        print("EXPLANATION")
        print("=" * 70)
        print(final['explanation'])
        
        # Also print solution candidates
        print("\n" + "=" * 70)
        print("ALL SOLUTION CANDIDATES")
        print("=" * 70)
        
        for i, candidate in enumerate(result["phases"]["solution_generation"]["candidates"], 1):
            print(f"\n--- Candidate {i}: {candidate['source']} ---")
            print(f"Success Chance: {candidate['estimated_success_chance']}/10")
            print(f"Pros: {', '.join(candidate['pros']) if candidate['pros'] else 'None listed'}")
            print(f"Cons: {', '.join(candidate['cons']) if candidate['cons'] else 'None listed'}")
        
    except Exception as e:
        print(f"\n❌ Error during analysis: {e}")
        import traceback
        traceback.print_exc()
        return 1
    
    return 0


async def run_specific_research(topic: str):
    """Run specific research topic"""
    
    researcher = IOSReverseEngineer()
    ensemble = get_ensemble()
    
    topics = {
        "touch": researcher.research_touch_injection,
        "structure": researcher.analyze_iohid_event_structure,
        "alternatives": researcher.find_working_alternatives,
        "zxtouch": researcher.analyze_zxtouch_approach
    }
    
    if topic not in topics:
        print(f"Unknown topic: {topic}")
        print(f"Available topics: {', '.join(topics.keys())}")
        return 1
    
    print(f"Running research: {topic}")
    result = await topics[topic]()
    
    print("\n" + "=" * 70)
    print("RESEARCH RESULTS")
    print("=" * 70)
    print(result.get("response", "No response"))
    
    return 0


async def quick_query(prompt: str):
    """Quick query to all models"""
    
    print(f"Query: {prompt}\n")
    
    ensemble = get_ensemble()
    
    system_prompt = """You are an expert iOS reverse engineer.
Be concise but technical. Focus on practical solutions."""
    
    try:
        responses = await ensemble.generate_all(prompt, system_prompt)
        
        for model, response in responses.items():
            print(f"\n{'='*70}")
            print(f"MODEL: {model.upper()}")
            print('='*70)
            print(response.content[:2000])  # Limit output
            if len(response.content) > 2000:
                print("\n... (truncated)")
        
    except Exception as e:
        print(f"Error: {e}")
        return 1
    
    return 0


def main():
    """Main entry point"""
    import argparse
    
    parser = argparse.ArgumentParser(
        description="Multi-Model AI Analysis for iOS Touch Injection"
    )
    
    parser.add_argument(
        "--full", "-f",
        action="store_true",
        help="Run full analysis (default)"
    )
    
    parser.add_argument(
        "--research", "-r",
        metavar="TOPIC",
        help="Run specific research topic (touch, structure, alternatives, zxtouch)"
    )
    
    parser.add_argument(
        "--query", "-q",
        metavar="PROMPT",
        help="Quick query to all models"
    )
    
    args = parser.parse_args()
    
    if args.query:
        return asyncio.run(quick_query(args.query))
    elif args.research:
        return asyncio.run(run_specific_research(args.research))
    else:
        return asyncio.run(run_touch_injection_analysis())


if __name__ == "__main__":
    sys.exit(main())