import { useEffect, useRef, useState } from "react";
import {
  PanResponder,
  Platform,
  StyleSheet,
  Text,
  TextInput,
  View,
  type TextStyle,
} from "react-native";
import { captionScale, type Caption } from "../app/composer";

export const captionBackgrounds = [
  "#00000059",
  "#FFFFFF8C",
  "transparent",
  "#FF3B30BF",
  "#007AFFBF",
];
export const captionColors = ["#FFFFFF", "#000000", "#FFCC00", "#FF2D55", "#007AFF"];
import { captionFonts } from "./captionFonts";
export { captionFonts } from "./captionFonts";

export function StoryCaption({
  caption,
  width,
  height,
  textScale = 1,
  maxWidth = Math.min(width - 88, 420),
  editing = false,
  selection,
  onSelection,
  onChange,
  onEdit,
  onDrag,
  onDragEnd,
  onDelete,
  disabled = false,
}: {
  caption: Caption;
  width: number;
  height: number;
  textScale?: number;
  maxWidth?: number;
  editing?: boolean;
  selection?: { start: number; end: number };
  onSelection?: (selection: { start: number; end: number }) => void;
  onChange?: (caption: Caption) => void;
  onEdit?: () => void;
  onDrag?: (caption?: Caption) => void;
  onDragEnd?: (caption: Caption) => void;
  onDelete?: () => void;
  disabled?: boolean;
}) {
  const [size, setSize] = useState({ width: 0, height: 0 });
  const input = useRef<TextInput>(null);
  useEffect(() => {
    if (!editing || Platform.OS !== "ios") return;
    // Attach the native accessory before UIKit presents the editor's input views.
    const frame = requestAnimationFrame(() => input.current?.focus());
    return () => cancelAnimationFrame(frame);
  }, [editing]);
  const current = useRef({
    caption,
    width,
    height,
    editing,
    disabled,
    onChange,
    onEdit,
    onDrag,
    onDragEnd,
  });
  current.current = {
    caption,
    width,
    height,
    editing,
    disabled,
    onChange,
    onEdit,
    onDrag,
    onDragEnd,
  };
  const motion = useRef({ x: 0, y: 0, scale: 1, distance: 0, moved: false, pinched: false });
  const pan = useRef(
    PanResponder.create({
      onStartShouldSetPanResponder: () =>
        !current.current.editing && !current.current.disabled && !!current.current.onChange,
      onMoveShouldSetPanResponder: () =>
        !current.current.editing && !current.current.disabled && !!current.current.onChange,
      onPanResponderGrant: () => {
        const item = current.current.caption;
        motion.current = {
          x: item.x,
          y: item.y,
          scale: item.scale,
          distance: 0,
          moved: false,
          pinched: false,
        };
      },
      onPanResponderMove: (event, gesture) => {
        const props = current.current,
          initial = motion.current;
        const [first, second] = event.nativeEvent.touches;
        if (first && second) {
          const distance = Math.hypot(second.pageX - first.pageX, second.pageY - first.pageY);
          if (!initial.distance) initial.distance = distance;
          initial.pinched = true;
          props.onDrag?.();
          props.onChange?.({
            ...props.caption,
            scale: captionScale({
              scale: (initial.scale * distance) / Math.max(1, initial.distance),
            }),
          });
        } else if (!initial.pinched && Math.hypot(gesture.dx, gesture.dy) > 3) {
          initial.moved = true;
          const next = {
            ...props.caption,
            x: Math.max(0, Math.min(1, initial.x + gesture.dx / props.width)),
            y: Math.max(0, Math.min(1, initial.y + gesture.dy / props.height)),
          };
          current.current.caption = next;
          props.onChange?.(next);
          props.onDrag?.(next);
        }
      },
      onPanResponderRelease: () => {
        const props = current.current;
        if (motion.current.moved && !motion.current.pinched) props.onDragEnd?.(props.caption);
        else if (!motion.current.pinched) props.onEdit?.();
        props.onDrag?.();
      },
      onPanResponderTerminate: () => current.current.onDrag?.(),
      onPanResponderTerminationRequest: () => false,
    }),
  ).current;
  const scale = caption.scale * textScale;
  const textStyle: TextStyle = {
    fontFamily: captionFonts[caption.font],
    fontWeight: "700",
    fontSize: 34 * scale,
    lineHeight: 42 * scale,
    color: captionColors[caption.color],
    textAlign: "center",
    includeFontPadding: false,
    paddingHorizontal: 18 * scale,
    paddingVertical: 12 * scale,
    minWidth: Math.min(90 * scale, maxWidth),
    minHeight: 58 * scale,
  };
  return (
    <View
      pointerEvents="box-none"
      style={{
        position: "absolute",
        width,
        alignItems: "center",
        top: editing ? height / 2 - 96 : caption.y * height,
        transform: [
          { translateX: editing ? 0 : (caption.x - 0.5) * width },
          { translateY: -size.height / 2 },
        ],
        zIndex: editing ? 2 : 0,
      }}
    >
      <View
        {...(!editing ? pan.panHandlers : {})}
        accessible={!editing && !!onChange}
        accessibilityLabel={caption.text || "Text"}
        accessibilityHint="Tap to edit, drag to move, or pinch to resize."
        accessibilityRole={onChange ? "adjustable" : undefined}
        accessibilityActions={[
          { name: "activate", label: "Edit text" },
          { name: "increment", label: "Larger text" },
          { name: "decrement", label: "Smaller text" },
          { name: "delete", label: "Delete text" },
        ]}
        onAccessibilityAction={(event) => {
          if (disabled) return;
          const action = event.nativeEvent.actionName;
          if (action === "activate") onEdit?.();
          else if (action === "delete") onDelete?.();
          else
            onChange?.({
              ...caption,
              scale: captionScale({
                scale: caption.scale + (action === "increment" ? 0.15 : -0.15),
              }),
            });
        }}
        onLayout={(event) => {
          const { width: w, height: h } = event.nativeEvent.layout;
          if (w !== size.width || h !== size.height) setSize({ width: w, height: h });
        }}
        style={{
          maxWidth,
          borderRadius: 16 * scale,
          backgroundColor: captionBackgrounds[caption.background],
        }}
      >
        <Text
          allowFontScaling={false}
          accessible={false}
          importantForAccessibility="no"
          style={[textStyle, editing && { opacity: 0 }]}
        >
          {caption.text || " "}
        </Text>
        {editing ? (
          <TextInput
            ref={input}
            accessibilityLabel="Story text"
            autoFocus={Platform.OS !== "ios"}
            multiline
            scrollEnabled={false}
            allowFontScaling={false}
            value={caption.text}
            selection={selection}
            onChangeText={(text) => onChange?.({ ...caption, text })}
            onSelectionChange={(event) => onSelection?.(event.nativeEvent.selection)}
            style={[StyleSheet.absoluteFill, textStyle, { textAlignVertical: "center" }]}
            underlineColorAndroid="transparent"
            selectionColor="#0095FF"
            cursorColor="#0095FF"
          />
        ) : null}
      </View>
    </View>
  );
}
