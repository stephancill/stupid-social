import { Host, Image } from "@expo/ui/swift-ui";
import { font, frame } from "@expo/ui/swift-ui/modifiers";
import type { ComponentProps } from "react";
import type * as Android from "./StoryIcon";
export type { StoryIconName } from "./StoryIcon";

const symbols = {
  close: "xmark",
  image: "photo",
  "photo-library": "photo.on.rectangle.angled",
  "delete-outline": "trash",
  check: "checkmark",
  "save-alt": "square.and.arrow.down",
  send: "paperplane.fill",
  person: "person.fill",
  "keyboard-hide": "keyboard.chevron.compact.down",
} as const;
export function StoryIcon({ name, size, color }: ComponentProps<typeof Android.StoryIcon>) {
  const placeholder = name === "photo-library";
  const dimension = placeholder ? 64 : size;
  return (
    <Host style={{ width: dimension, height: placeholder ? 52 : size }} pointerEvents="none">
      <Image
        systemName={symbols[name]}
        color={color}
        modifiers={[
          font({
            size: placeholder ? 46 : name === "send" ? 22 : 17,
            weight: placeholder ? "regular" : "semibold",
          }),
          frame({ width: dimension, height: placeholder ? 52 : size }),
        ]}
      />
    </Host>
  );
}
