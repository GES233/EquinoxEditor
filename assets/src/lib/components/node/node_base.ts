import { Position } from "./position";

export interface BodeBase {
    // Or use Mixin to inject these fields?
    id: string,
    type: string,
    label: string,
    position: Position,
}
