import { requireNativeView } from "expo";
import { type ViewProps } from "react-native";
import type { CaptionAccessoryProps } from "./CaptionAccessory";
import { captionBackgrounds, captionColors, captionFonts } from "./StoryCaption";

const Toolbar = requireNativeView<
  ViewProps & {
    backgroundIndex: number;
    colorIndex: number;
    fontIndex: number;
    onAction: (event: { nativeEvent: { action: string } }) => void;
  }
>("StoryCaptionToolbar");

export function CaptionAccessory({ caption, onChange, onDone }: CaptionAccessoryProps) {
  return (
    <Toolbar
      style={{ position: "absolute", width: 0, height: 0 }}
      backgroundIndex={caption.background}
      colorIndex={caption.color}
      fontIndex={caption.font}
      onAction={({ nativeEvent: { action } }) => {
        if (action === "done") onDone();
        else if (action === "background")
          onChange({
            ...caption,
            background: (caption.background + 1) % captionBackgrounds.length,
          });
        else if (action === "font")
          onChange({ ...caption, font: (caption.font + 1) % captionFonts.length });
        else if (action === "color")
          onChange({ ...caption, color: (caption.color + 1) % captionColors.length });
      }}
    />
  );
}
