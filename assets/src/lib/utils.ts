let nextId = 0;

export function genNodeId(): string {
  return `n_${++nextId}_${Date.now().toString(36)}`;
}

export function genEdgeId(source: string, sourceHandle: string, target: string, targetHandle: string): string {
  return `e_${source}_${sourceHandle}_${target}_${targetHandle}`;
}

export type SFlowNode = {
  id: string;
  type: string;
  position: { x: number; y: number };
  data: {
    label: string;
    module?: string;
    inputs: { name: string; type: string }[];
    outputs: { name: string; type: string }[];
    properties: Record<string, any>;
  };
};

export type SFlowEdge = {
  id: string;
  source: string;
  sourceHandle: string;
  target: string;
  targetHandle: string;
};

export function graphPayloadToSFlow(graph: any): { nodes: SFlowNode[], edges: SFlowEdge[] } {
  if (!graph || !graph.nodes) return { nodes: [], edges: [] };
  
  // graph.nodes 可能是对象 (Map) 也可能是数组
  const rawNodes = Array.isArray(graph.nodes) ? graph.nodes : Object.values(graph.nodes);
  const rawEdges = Array.isArray(graph.edges) ? graph.edges : Object.values(graph.edges || {});
  
  const nodes: SFlowNode[] = rawNodes.map((n: any) => ({
    id: n.id,
    type: n.extra?.type || "dynamic",
    position: n.extra?.position || { x: 0, y: 0 },
    data: n.extra?.data || {
      label: n.id, // Fallback
      inputs: (n.inputs || []).map((p: string) => ({ name: p, type: "any" })),
      outputs: (n.outputs || []).map((p: string) => ({ name: p, type: "any" })),
      properties: n.options || {}
    }
  }));

  const edges: SFlowEdge[] = rawEdges.map((e: any, idx: number) => ({
    id: `e_${e.from_node}_${e.from_port}_${e.to_node}_${e.to_port}`,
    source: e.from_node,
    sourceHandle: e.from_port,
    target: e.to_node,
    targetHandle: e.to_port
  }));

  return { nodes, edges };
}

export function stepDefToTemplateNode(stepDef: any): SFlowNode {
  return {
    id: genNodeId(),
    type: "dynamic",
    position: { x: 0, y: 0 },
    data: {
      label: stepDef.name,
      module: stepDef.module,
      inputs: stepDef.inputs || [],
      outputs: stepDef.outputs || [],
      properties: stepDef.properties || {},
    },
  };
}

export function sflowToGraphPayload(nodes: SFlowNode[], edges: SFlowEdge[]) {
  return {
    nodes: nodes.map((n) => ({
      id: n.id,
      type: n.type,
      data: n.data,
      position: n.position // Send position to backend so it gets saved in extra
    })),
    edges: edges.map((e) => ({
      id: e.id,
      source: e.source,
      sourceHandle: e.sourceHandle,
      target: e.target,
      targetHandle: e.targetHandle,
    })),
  };
}
