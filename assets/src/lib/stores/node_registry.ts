import type { Component } from "svelte";

const registry = new Map<string, Component>();

export function registerNodeType(name: string, component: Component): void {
  registry.set(name, component);
}

export function getNodeType(name: string): Component | undefined {
  return registry.get(name);
}

export function getAllNodeTypes(): Record<string, Component> {
  return Object.fromEntries(registry);
}
