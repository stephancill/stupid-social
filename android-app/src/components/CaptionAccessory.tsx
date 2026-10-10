import type { Caption } from "../app/composer";
export type CaptionAccessoryProps = {
  caption: Caption;
  onChange: (caption: Caption) => void;
  onDone: () => void;
};
export function CaptionAccessory(_props: CaptionAccessoryProps) {
  return null;
}
