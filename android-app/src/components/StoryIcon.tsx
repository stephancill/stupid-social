import { MaterialIcons } from "@expo/vector-icons";

export type StoryIconName =
  | "close"
  | "image"
  | "photo-library"
  | "delete-outline"
  | "check"
  | "save-alt"
  | "send"
  | "person"
  | "keyboard-hide";
export function StoryIcon({
  name,
  size,
  color,
}: {
  name: StoryIconName;
  size: number;
  color: string;
}) {
  return <MaterialIcons name={name} size={size} color={color} />;
}
