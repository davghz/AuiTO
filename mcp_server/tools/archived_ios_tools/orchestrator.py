"""
AI Orchestrator for iOS Touch Injection
Coordinates multi-model analysis and solution synthesis
"""

import asyncio
import json
from typing import Dict, List, Any, Optional
from dataclasses import dataclass, asdict
from datetime import datetime

from .model_clients import get_ensemble


@dataclass
class AnalysisResult:
    """Result from a single model analysis"""
    model: str
    approach: str
    confidence: int  # 1-10
    code_provided: bool
    key_insights: List[str]
    potential_issues: List[str]
    raw_response: str


@dataclass
class SolutionCandidate:
    """A candidate solution with metadata"""
    source: str
    code: str
    description: str
    pros: List[str]
    cons: List[str]
    estimated_success_chance: int  # 1-10


class TouchInjectionOrchestrator:
    """
    Orchestrates AI models to solve iOS touch injection problems.
    
    Uses a multi-phase approach:
    1. Problem Analysis - All models analyze the problem independently
    2. Solution Generation - Each model proposes solutions
    3. Cross-Validation - Models critique each other's solutions
    4. Synthesis - Combine best elements into final recommendation
    """
    
    def __init__(self):
        self.ensemble = get_ensemble()
        self.analysis_history = []
        self.solution_candidates = []
    
    async def analyze_problem(self, context: Dict[str, Any]) -> Dict[str, Any]:
        """
        Phase 1: Multi-model problem analysis
        
        Each model independently analyzes the problem and provides insights.
        """
        ios_version = context.get("ios_version", "13.2.3")
        device = context.get("device", "iPhone X")
        symptoms = context.get("symptoms", "Events dispatch without error but don't register")
        
        # Problem analysis prompt
        analysis_prompt = f"""Analyze this iOS touch injection problem:

ENVIRONMENT:
- iOS Version: {ios_version}
- Device: {device}
- Jailbreak: checkra1n
- Process: SpringBoard (MobileSubstrate tweak)

SYMPTOMS:
{symptoms}

CURRENT IMPLEMENTATION:
- Uses IOHIDEventCreateDigitizerEvent
- Proper iOS 13 setup: CreateSimpleClient → SetDispatchQueue → Activate
- Sender ID: 0xDEFACEDBEEFFECE5
- Events dispatched without errors
- No crashes, no errors in logs
- Touch simply doesn't register on UI

Your task:
1. Identify all possible causes for silent failure
2. Suggest diagnostic steps to narrow down the issue
3. Rate each potential cause by likelihood (1-10)
4. Provide the most likely root cause

Be specific and technical. Think step by step."""

        print("[Orchestrator] Phase 1: Multi-model problem analysis...")
        responses = await self.ensemble.generate_all(analysis_prompt)
        
        results = []
        for model_name, response in responses.items():
            result = AnalysisResult(
                model=model_name,
                approach=self._extract_approach(response.content),
                confidence=self._extract_confidence(response.content),
                code_provided="```" in response.content,
                key_insights=self._extract_insights(response.content),
                potential_issues=self._extract_issues(response.content),
                raw_response=response.content
            )
            results.append(result)
            print(f"  [Phase 1] {model_name}: confidence={result.confidence}, code={result.code_provided}")
        
        self.analysis_history.append({
            "phase": "problem_analysis",
            "timestamp": datetime.now().isoformat(),
            "results": [asdict(r) for r in results]
        })
        
        return {
            "phase": "problem_analysis",
            "results": results,
            "consensus": self._find_consensus(results)
        }
    
    async def generate_solutions(self, analysis_results: List[AnalysisResult]) -> List[SolutionCandidate]:
        """
        Phase 2: Solution generation
        
        Each model generates a complete solution based on the problem analysis.
        """
        consensus = self._find_consensus(analysis_results)
        
        solution_prompt = f"""Generate a COMPLETE, WORKING solution for iOS 13.2.3 touch injection.

PROBLEM CONSENSUS:
{json.dumps(consensus, indent=2)}

REQUIREMENTS:
1. Complete Objective-C implementation
2. All required headers
3. Proper initialization sequence
4. Event creation code
5. Error handling
6. Comments explaining key parts

The code MUST be:
- Copy-paste ready
- Specifically for iOS 13.2.3
- Working on checkra1n jailbreak
- Running in SpringBoard process

If you're unsure about a specific detail, indicate it clearly.

Provide the complete solution now."""

        print("[Orchestrator] Phase 2: Solution generation...")
        responses = await self.ensemble.generate_all(solution_prompt)
        
        candidates = []
        for model_name, response in responses.items():
            code = self._extract_code(response.content)
            candidate = SolutionCandidate(
                source=model_name,
                code=code,
                description=self._extract_description(response.content),
                pros=self._extract_pros(response.content),
                cons=self._extract_cons(response.content),
                estimated_success_chance=self._estimate_success(response.content)
            )
            candidates.append(candidate)
            print(f"  [Phase 2] {model_name}: {len(code)} chars code, success chance: {candidate.estimated_success_chance}/10")
        
        self.solution_candidates = candidates
        return candidates
    
    async def cross_validate(self, candidates: List[SolutionCandidate]) -> Dict[str, Any]:
        """
        Phase 3: Cross-validation
        
        Models critique and validate each other's solutions.
        """
        print("[Orchestrator] Phase 3: Cross-validation...")
        
        # Prepare candidate summaries for critique
        candidate_summaries = []
        for i, c in enumerate(candidates):
            candidate_summaries.append(f"""CANDIDATE {i+1} ({c.source}):
Pros: {', '.join(c.pros)}
Cons: {', '.join(c.cons)}
Estimated Success: {c.estimated_success_chance}/10
---""")
        
        validation_prompt = f"""Validate these touch injection solutions for iOS 13.2.3:

{candidate_summaries}

For each candidate:
1. Identify potential bugs or issues
2. Check if iOS 13.2.3 requirements are met
3. Suggest improvements
4. Rate final viability (1-10)

Which candidate is most likely to work and why?"""

        responses = await self.ensemble.generate_all(validation_prompt)
        
        validations = []
        for model_name, response in responses.items():
            validations.append({
                "model": model_name,
                "analysis": response.content,
                "ratings": self._extract_ratings(response.content, len(candidates))
            })
        
        return {
            "phase": "cross_validation",
            "validations": validations,
            "aggregated_ratings": self._aggregate_ratings(validations, candidates)
        }
    
    async def synthesize_final(self, 
                               analysis: Dict[str, Any],
                               candidates: List[SolutionCandidate],
                               validation: Dict[str, Any]) -> Dict[str, Any]:
        """
        Phase 4: Final synthesis
        
        Combine the best elements from all solutions into a final recommendation.
        """
        best_candidate = max(candidates, key=lambda c: c.estimated_success_chance)
        
        synthesis_prompt = f"""Create the FINAL, OPTIMIZED solution for iOS 13.2.3 touch injection.

BEST CANDIDATE ({best_candidate.source}):
```objc
{best_candidate.code}
```

VALIDATION FEEDBACK:
{json.dumps(validation['validations'], indent=2)}

Your task:
1. Incorporate fixes from validation feedback
2. Optimize the code for iOS 13.2.3
3. Add any missing error handling
4. Ensure all iOS 13 requirements are met
5. Make it production-ready

Provide the complete, final implementation."""

        print("[Orchestrator] Phase 4: Final synthesis...")
        response = await self.ensemble.clients["deepseek"].generate(synthesis_prompt)
        
        final_code = self._extract_code(response.content)
        
        return {
            "phase": "final_synthesis",
            "final_code": final_code,
            "explanation": self._extract_description(response.content),
            "recommended_candidate": best_candidate.source,
            "success_confidence": best_candidate.estimated_success_chance
        }
    
    async def run_full_analysis(self, context: Dict[str, Any]) -> Dict[str, Any]:
        """Run complete multi-phase analysis"""
        print("=" * 60)
        print("TOUCH INJECTION ORCHESTRATOR - Full Analysis")
        print("=" * 60)
        
        # Phase 1
        analysis = await self.analyze_problem(context)
        
        # Phase 2
        candidates = await self.generate_solutions(analysis["results"])
        
        # Phase 3
        validation = await self.cross_validate(candidates)
        
        # Phase 4
        final = await self.synthesize_final(analysis, candidates, validation)
        
        result = {
            "timestamp": datetime.now().isoformat(),
            "context": context,
            "phases": {
                "problem_analysis": analysis,
                "solution_generation": {
                    "candidates": [asdict(c) for c in candidates]
                },
                "cross_validation": validation,
                "final_synthesis": final
            }
        }
        
        print("\n" + "=" * 60)
        print(f"Analysis Complete - Success Confidence: {final['success_confidence']}/10")
        print("=" * 60)
        
        return result
    
    # Helper methods
    def _extract_approach(self, text: str) -> str:
        """Extract the main approach from analysis"""
        if "sender id" in text.lower():
            return "sender_id_fix"
        elif "dispatch" in text.lower():
            return "dispatch_fix"
        elif "queue" in text.lower():
            return "queue_fix"
        elif "alternative" in text.lower():
            return "alternative_method"
        return "unknown"
    
    def _extract_confidence(self, text: str) -> int:
        """Extract confidence rating from text"""
        import re
        # Look for patterns like "confidence: 8" or "8/10" or "likely: 9"
        patterns = [
            r'confidence[:\s]+(\d+)',
            r'(\d+)[\s/]*10',
            r'likelihood[:\s]+(\d+)',
        ]
        for pattern in patterns:
            match = re.search(pattern, text.lower())
            if match:
                return min(10, max(1, int(match.group(1))))
        return 5
    
    def _extract_insights(self, text: str) -> List[str]:
        """Extract key insights"""
        insights = []
        lines = text.split('\n')
        for line in lines:
            if line.strip().startswith('- ') or line.strip().startswith('* '):
                insight = line.strip()[2:].strip()
                if len(insight) > 10:
                    insights.append(insight)
        return insights[:5]
    
    def _extract_issues(self, text: str) -> List[str]:
        """Extract potential issues"""
        issues = []
        in_issues = False
        for line in text.split('\n'):
            if 'issue' in line.lower() or 'problem' in line.lower():
                in_issues = True
            if in_issues and (line.strip().startswith('- ') or line.strip().startswith('* ')):
                issue = line.strip()[2:].strip()
                if len(issue) > 10:
                    issues.append(issue)
        return issues[:5]
    
    def _extract_code(self, text: str) -> str:
        """Extract code blocks from text"""
        import re
        code_blocks = re.findall(r'```(?:objc|c|objective-c)?\n(.*?)```', text, re.DOTALL)
        if code_blocks:
            return '\n\n'.join(code_blocks)
        return ""
    
    def _extract_description(self, text: str) -> str:
        """Extract main description"""
        lines = text.split('\n')
        description = []
        for line in lines:
            if not line.startswith('```') and not line.startswith('#'):
                description.append(line)
            if len(description) > 20:
                break
        return '\n'.join(description).strip()[:500]
    
    def _extract_pros(self, text: str) -> List[str]:
        """Extract pros"""
        pros = []
        in_pros = False
        for line in text.split('\n'):
            if 'pro' in line.lower() or 'advantage' in line.lower():
                in_pros = True
            if in_pros and (line.strip().startswith('- ') or line.strip().startswith('* ')):
                pro = line.strip()[2:].strip()
                if len(pro) > 5:
                    pros.append(pro)
        return pros[:3]
    
    def _extract_cons(self, text: str) -> List[str]:
        """Extract cons"""
        cons = []
        in_cons = False
        for line in text.split('\n'):
            if 'con' in line.lower() or 'disadvantage' in line.lower():
                in_cons = True
            if in_cons and (line.strip().startswith('- ') or line.strip().startswith('* ')):
                con = line.strip()[2:].strip()
                if len(con) > 5:
                    cons.append(con)
        return cons[:3]
    
    def _estimate_success(self, text: str) -> int:
        """Estimate success chance from text"""
        return self._extract_confidence(text)
    
    def _find_consensus(self, results: List[AnalysisResult]) -> Dict[str, Any]:
        """Find consensus across analyses"""
        approaches = {}
        for r in results:
            if r.approach not in approaches:
                approaches[r.approach] = 0
            approaches[r.approach] += r.confidence
        
        all_insights = []
        for r in results:
            all_insights.extend(r.key_insights)
        
        return {
            "most_common_approach": max(approaches.items(), key=lambda x: x[1])[0] if approaches else "unknown",
            "average_confidence": sum(r.confidence for r in results) / len(results) if results else 0,
            "shared_insights": list(set(all_insights))[:5],
            "total_analyses": len(results)
        }
    
    def _extract_ratings(self, text: str, num_candidates: int) -> Dict[int, int]:
        """Extract ratings for each candidate"""
        import re
        ratings = {}
        for i in range(1, num_candidates + 1):
            # Look for "Candidate 1: 8/10" or similar
            pattern = rf'candidate\s*{i}[:\s]+(\d+)'
            match = re.search(pattern, text.lower())
            if match:
                ratings[i] = int(match.group(1))
        return ratings
    
    def _aggregate_ratings(self, validations: List[Dict], candidates: List[SolutionCandidate]) -> List[Dict]:
        """Aggregate ratings across all validations"""
        aggregated = []
        for i, c in enumerate(candidates, 1):
            total = 0
            count = 0
            for v in validations:
                if i in v.get("ratings", {}):
                    total += v["ratings"][i]
                    count += 1
            avg = total / count if count > 0 else c.estimated_success_chance
            aggregated.append({
                "candidate": i,
                "source": c.source,
                "average_rating": round(avg, 1),
                "num_votes": count
            })
        return sorted(aggregated, key=lambda x: x["average_rating"], reverse=True)


# Singleton instance
_orchestrator = None

def get_orchestrator() -> TouchInjectionOrchestrator:
    global _orchestrator
    if _orchestrator is None:
        _orchestrator = TouchInjectionOrchestrator()
    return _orchestrator