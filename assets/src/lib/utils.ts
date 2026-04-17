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
