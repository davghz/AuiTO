"""
Multi-Model AI Client Connectors
Supports: Arcee AI, TNGTech, DeepSeek, Qwen, Anthropic
"""

import os
import json
import asyncio
from typing import Optional, Dict, Any, List
from dataclasses import dataclass
from abc import ABC, abstractmethod

# Try to import aiohttp, fall back to requests
try:
    import aiohttp
    ASYNC_AVAILABLE = True
except ImportError:
    import requests
    ASYNC_AVAILABLE = False


@dataclass
class ModelResponse:
    content: str
    model: str
    usage: Dict[str, int]
    raw_response: Any = None


class BaseModelClient(ABC):
    """Base class for AI model clients"""
    
    def __init__(self, api_key: Optional[str] = None, base_url: Optional[str] = None):
        self.api_key = api_key or os.environ.get(self.get_env_key())
        self.base_url = base_url or self.get_default_url()
    
    @abstractmethod
    def get_env_key(self) -> str:
        pass
    
    @abstractmethod
    def get_default_url(self) -> str:
        pass
    
    @abstractmethod
    async def generate(self, prompt: str, system_prompt: Optional[str] = None, 
                      temperature: float = 0.7, max_tokens: int = 4000) -> ModelResponse:
        pass


class ArceeClient(BaseModelClient):
    """Arcee AI Trinity Large Preview Client"""
    
    MODEL = "arcee-ai/trinity-large-preview:free"
    
    def get_env_key(self) -> str:
        return "ARCEE_API_KEY"
    
    def get_default_url(self) -> str:
        return "https://api.arcee.ai/v1"
    
    async def generate(self, prompt: str, system_prompt: Optional[str] = None,
                      temperature: float = 0.7, max_tokens: int = 4000) -> ModelResponse:
        """Generate using Arcee AI Trinity Large"""
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }
        
        messages = []
        if system_prompt:
            messages.append({"role": "system", "content": system_prompt})
        messages.append({"role": "user", "content": prompt})
        
        data = {
            "model": self.MODEL,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens
        }
        
        if ASYNC_AVAILABLE:
            async with aiohttp.ClientSession() as session:
                async with session.post(f"{self.base_url}/chat/completions", 
                                       headers=headers, json=data) as resp:
                    result = await resp.json()
        else:
            resp = requests.post(f"{self.base_url}/chat/completions", 
                                headers=headers, json=data)
            result = resp.json()
        
        return ModelResponse(
            content=result["choices"][0]["message"]["content"],
            model=self.MODEL,
            usage=result.get("usage", {}),
            raw_response=result
        )


class DeepSeekClient(BaseModelClient):
    """DeepSeek R1 0528 Client"""
    
    MODEL = "deepseek/deepseek-r1-0528:free"
    
    def get_env_key(self) -> str:
        return "DEEPSEEK_API_KEY"
    
    def get_default_url(self) -> str:
        return "https://api.deepseek.com/v1"
    
    async def generate(self, prompt: str, system_prompt: Optional[str] = None,
                      temperature: float = 0.7, max_tokens: int = 4000) -> ModelResponse:
        """Generate using DeepSeek R1"""
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }
        
        messages = []
        if system_prompt:
            messages.append({"role": "system", "content": system_prompt})
        messages.append({"role": "user", "content": prompt})
        
        data = {
            "model": self.MODEL,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens
        }
        
        if ASYNC_AVAILABLE:
            async with aiohttp.ClientSession() as session:
                async with session.post(f"{self.base_url}/chat/completions",
                                       headers=headers, json=data) as resp:
                    result = await resp.json()
        else:
            resp = requests.post(f"{self.base_url}/chat/completions",
                                headers=headers, json=data)
            result = resp.json()
        
        return ModelResponse(
            content=result["choices"][0]["message"]["content"],
            model=self.MODEL,
            usage=result.get("usage", {}),
            raw_response=result
        )


class QwenClient(BaseModelClient):
    """Qwen3 Coder Client"""
    
    MODEL = "qwen/qwen3-coder:free"
    
    def get_env_key(self) -> str:
        return "QWEN_API_KEY"
    
    def get_default_url(self) -> str:
        return "https://api.qwen.ai/v1"
    
    async def generate(self, prompt: str, system_prompt: Optional[str] = None,
                      temperature: float = 0.7, max_tokens: int = 4000) -> ModelResponse:
        """Generate using Qwen3 Coder"""
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }
        
        messages = []
        if system_prompt:
            messages.append({"role": "system", "content": system_prompt})
        messages.append({"role": "user", "content": prompt})
        
        data = {
            "model": self.MODEL,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens
        }
        
        try:
            if ASYNC_AVAILABLE:
                async with aiohttp.ClientSession() as session:
                    async with session.post(f"{self.base_url}/chat/completions",
                                           headers=headers, json=data) as resp:
                        result = await resp.json()
            else:
                resp = requests.post(f"{self.base_url}/chat/completions",
                                    headers=headers, json=data)
                result = resp.json()
            
            return ModelResponse(
                content=result["choices"][0]["message"]["content"],
                model=self.MODEL,
                usage=result.get("usage", {}),
                raw_response=result
            )
        except Exception as e:
            # Fallback: try OpenRouter or other compatible API
            return await self._fallback_generate(prompt, system_prompt, temperature, max_tokens)
    
    async def _fallback_generate(self, prompt: str, system_prompt: Optional[str],
                                temperature: float, max_tokens: int) -> ModelResponse:
        """Fallback using OpenRouter"""
        openrouter_key = os.environ.get("OPENROUTER_API_KEY")
        if not openrouter_key:
            raise RuntimeError("No Qwen API key and no OpenRouter fallback")
        
        headers = {
            "Authorization": f"Bearer {openrouter_key}",
            "Content-Type": "application/json"
        }
        
        messages = []
        if system_prompt:
            messages.append({"role": "system", "content": system_prompt})
        messages.append({"role": "user", "content": prompt})
        
        data = {
            "model": "qwen/qwen-2.5-coder-32b-instruct",
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens
        }
        
        if ASYNC_AVAILABLE:
            async with aiohttp.ClientSession() as session:
                async with session.post("https://openrouter.ai/api/v1/chat/completions",
                                       headers=headers, json=data) as resp:
                    result = await resp.json()
        else:
            resp = requests.post("https://openrouter.ai/api/v1/chat/completions",
                                headers=headers, json=data)
            result = resp.json()
        
        return ModelResponse(
            content=result["choices"][0]["message"]["content"],
            model="qwen/qwen-2.5-coder-32b-instruct",
            usage=result.get("usage", {}),
            raw_response=result
        )


class AnthropicClient(BaseModelClient):
    """Anthropic Claude Opus 4.5 Client"""
    
    MODEL = "claude-opus-4.5-20251101"
    
    def get_env_key(self) -> str:
        return "ANTHROPIC_API_KEY"
    
    def get_default_url(self) -> str:
        return "https://api.anthropic.com/v1"
    
    async def generate(self, prompt: str, system_prompt: Optional[str] = None,
                      temperature: float = 0.7, max_tokens: int = 4000) -> ModelResponse:
        """Generate using Claude Opus 4.5"""
        headers = {
            "x-api-key": self.api_key,
            "Content-Type": "application/json",
            "anthropic-version": "2023-06-01"
        }
        
        data = {
            "model": self.MODEL,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "messages": [{"role": "user", "content": prompt}]
        }
        
        if system_prompt:
            data["system"] = system_prompt
        
        if ASYNC_AVAILABLE:
            async with aiohttp.ClientSession() as session:
                async with session.post(f"{self.base_url}/messages",
                                       headers=headers, json=data) as resp:
                    result = await resp.json()
        else:
            resp = requests.post(f"{self.base_url}/messages",
                                headers=headers, json=data)
            result = resp.json()
        
        content = ""
        if "content" in result and len(result["content"]) > 0:
            content = result["content"][0].get("text", "")
        
        return ModelResponse(
            content=content,
            model=self.MODEL,
            usage={
                "input_tokens": result.get("usage", {}).get("input_tokens", 0),
                "output_tokens": result.get("usage", {}).get("output_tokens", 0)
            },
            raw_response=result
        )


class MultiModelEnsemble:
    """Ensemble of multiple AI models for consensus-based answers"""
    
    def __init__(self):
        self.clients = {
            "arcee": ArceeClient(),
            "deepseek": DeepSeekClient(),
            "qwen": QwenClient(),
            "anthropic": AnthropicClient()
        }
    
    async def generate_all(self, prompt: str, system_prompt: Optional[str] = None) -> Dict[str, ModelResponse]:
        """Generate responses from all available models"""
        tasks = {}
        for name, client in self.clients.items():
            if client.api_key:  # Only query if API key is available
                tasks[name] = asyncio.create_task(
                    self._safe_generate(client, prompt, system_prompt)
                )
        
        results = {}
        for name, task in tasks.items():
            try:
                result = await task
                if result:
                    results[name] = result
            except Exception as e:
                print(f"[MultiModelEnsemble] {name} failed: {e}")
        
        return results
    
    async def _safe_generate(self, client: BaseModelClient, prompt: str, 
                            system_prompt: Optional[str]) -> Optional[ModelResponse]:
        """Safely generate with error handling"""
        try:
            return await client.generate(prompt, system_prompt)
        except Exception as e:
            print(f"[MultiModelEnsemble] Error with {client.__class__.__name__}: {e}")
            return None
    
    async def generate_consensus(self, prompt: str, system_prompt: Optional[str] = None) -> str:
        """Generate consensus response from all models"""
        results = await self.generate_all(prompt, system_prompt)
        
        if not results:
            return "Error: No models available"
        
        # Combine responses with model attribution
        combined = "# Multi-Model Analysis\n\n"
        for name, response in results.items():
            combined += f"## {name.upper()} ({response.model})\n\n"
            combined += response.content
            combined += "\n\n---\n\n"
        
        return combined


# Singleton instance
_ensemble = None

def get_ensemble() -> MultiModelEnsemble:
    global _ensemble
    if _ensemble is None:
        _ensemble = MultiModelEnsemble()
    return _ensemble