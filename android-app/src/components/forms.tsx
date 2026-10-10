import { useEffect, useLayoutEffect, useState, type ReactNode } from "react";
import {
  useWindowDimensions,
  ActivityIndicator,
  KeyboardAvoidingView,
  ScrollView,
  StyleSheet,
  Text,
  View,
  type NativeScrollEvent,
  type NativeSyntheticEvent,
  type StyleProp,
  type TextStyle,
} from "react-native";
import { useNavigation } from "@react-navigation/native";
import { useHeaderHeight } from "@react-navigation/elements";
import { SafeAreaView } from "react-native-safe-area-context";
import { Ionicons } from "@expo/vector-icons";
import {
  Column,
  Row as NativeRow,
  Image as NativeImage,
  IconButton,
  ListItem,
  RNHostView,
  Switch,
  Surface,
  Text as NativeText,
  OutlinedTextField,
  useNativeState,
} from "@expo/ui/jetpack-compose";
import {
  alpha,
  clickable,
  clip,
  fillMaxSize,
  fillMaxWidth,
  padding,
  size,
  Shapes,
  toggleable,
} from "@expo/ui/jetpack-compose/modifiers";
import { NativeHost, MaterialIcon, NativeAvatar } from "./material";
import { androidSmallText } from "./typography";
import type { Actor } from "../app/models";
import { networkImages, useSocialColors } from "./social";

export function useFormColors() {
  const c = useSocialColors();
  return { ...c, page: c.background, group: c.fill };
}
const regularText = { fontSize: 16, lineHeight: 24, letterSpacing: 0 };
const smallText = androidSmallText;
export function FormText({
  children,
  secondary = false,
  style,
}: {
  children: ReactNode;
  secondary?: boolean;
  style?: StyleProp<TextStyle>;
}) {
  const c = useFormColors();
  return (
    <Text
      style={[
        { color: secondary ? c.secondary : c.text, fontSize: 16, lineHeight: 24, flexShrink: 1 },
        style,
      ]}
    >
      {children}
    </Text>
  );
}
export function FormScreen({
  title,
  children,
  trailing,
  bottom,
  onScroll,
}: {
  title: string;
  children: ReactNode;
  trailing?: ReactNode;
  bottom?: ReactNode;
  onScroll?: (event: NativeSyntheticEvent<NativeScrollEvent>) => void;
  inline?: boolean;
  grouped?: boolean;
}) {
  const navigation = useNavigation(),
    c = useFormColors(),
    headerHeight = useHeaderHeight();
  useLayoutEffect(() => {
    navigation.setOptions({ title, headerRight: trailing ? () => trailing : undefined });
  }, [navigation, title, trailing]);
  return (
    <KeyboardAvoidingView
      behavior="height"
      keyboardVerticalOffset={headerHeight}
      style={{ flex: 1, backgroundColor: c.page }}
    >
      <SafeAreaView edges={["left", "right", "bottom"]} style={{ flex: 1 }}>
        <ScrollView
          keyboardShouldPersistTaps="handled"
          keyboardDismissMode="on-drag"
          onScroll={onScroll}
          scrollEventThrottle={100}
          contentContainerStyle={{ paddingTop: 8, paddingBottom: 24 }}
        >
          {children}
        </ScrollView>
        {bottom}
      </SafeAreaView>
    </KeyboardAvoidingView>
  );
}
export function FormSection({
  title,
  children,
  footer,
  onTitlePress,
}: {
  title?: string;
  children: ReactNode;
  footer?: string;
  onTitlePress?: () => void;
  separators?: boolean;
}) {
  const c = useFormColors();
  return (
    <View style={{ marginHorizontal: 16, marginBottom: 24 }}>
      {title ? (
        <NativeHost matchContents={{ vertical: true }}>
          <Column
            modifiers={[
              fillMaxWidth(),
              ...(onTitlePress ? [clickable(onTitlePress)] : []),
              padding(16, 8, 16, 12),
            ]}
          >
            <NativeText color={c.blue} style={{ ...regularText, fontWeight: "500" }}>
              {title}
            </NativeText>
          </Column>
        </NativeHost>
      ) : null}
      <View style={{ borderRadius: 24, overflow: "hidden" }}>
        {/* Keep mixed native rows and React media in their normal measuring layout. */}
        <NativeHost pointerEvents="none" style={StyleSheet.absoluteFill}>
          <Surface color={c.group} modifiers={[fillMaxSize(), clip(Shapes.RoundedCorner(24))]} />
        </NativeHost>
        {children}
      </View>
      {footer ? (
        <NativeHost matchContents={{ vertical: true }}>
          <NativeText
            color={c.secondary}
            style={smallText}
            modifiers={[fillMaxWidth(), padding(16, 8, 16, 0)]}
          >
            {footer}
          </NativeText>
        </NativeHost>
      ) : null}
    </View>
  );
}
export function FormRow({
  actor,
  subtitle,
  verified = false,
  title,
  value,
  children,
  onPress,
  disabled = false,
  destructive = false,
  link = false,
  multiline = false,
  label,
  external = false,
  invalid = false,
  plain = false,
}: {
  actor?: Actor;
  subtitle?: string;
  verified?: boolean;
  title?: string;
  value?: string;
  children?: ReactNode;
  onPress?: () => void;
  disabled?: boolean;
  destructive?: boolean;
  link?: boolean;
  centered?: boolean;
  multiline?: boolean;
  label?: string;
  external?: boolean;
  invalid?: boolean;
  plain?: boolean;
}) {
  const c = useFormColors();
  // Passive React content needs an explicit height when hosted inside a Compose list item.
  const { width } = useWindowDimensions(),
    [rowWidth, setRowWidth] = useState<number>(),
    [contentHeight, setContentHeight] = useState(0);
  const color = destructive || invalid ? c.error : onPress && !link && !plain ? c.blue : c.text;
  const supportingValue = value !== undefined && (multiline || link);
  return (
    <View onLayout={(event) => setRowWidth(event.nativeEvent.layout.width)}>
      <NativeHost
        matchContents={children ? undefined : { vertical: true }}
        style={children ? { height: Math.max(56, contentHeight + 16) } : undefined}
      >
        <ListItem
          colors={{ containerColor: "transparent" }}
          modifiers={[
            fillMaxWidth(),
            ...(onPress && !disabled ? [clickable(onPress)] : []),
            ...(disabled ? [alpha(0.38)] : []),
          ]}
        >
          {actor ? (
            <ListItem.LeadingContent>
              <NativeAvatar actor={actor} avatarSize={subtitle ? 44 : 24} />
            </ListItem.LeadingContent>
          ) : null}
          <ListItem.HeadlineContent>
            {children ? (
              <RNHostView matchContents modifiers={[fillMaxWidth()]}>
                <View
                  onLayout={(event) => setContentHeight(event.nativeEvent.layout.height)}
                  accessibilityLabel={label}
                  style={{
                    width: Math.max(0, (rowWidth ?? width) - 32 - (external ? 32 : 0)),
                    flexDirection: "row",
                    alignItems: "center",
                    gap: 12,
                  }}
                >
                  {children}
                </View>
              </RNHostView>
            ) : (
              <NativeRow horizontalArrangement={{ spacedBy: 6 }} verticalAlignment="center">
                {actor && !subtitle ? (
                  <NativeImage
                    source={networkImages[actor.network] as number}
                    modifiers={[size(16, 16)]}
                  />
                ) : null}
                <NativeText color={color} style={regularText}>
                  {title}
                </NativeText>
                {verified ? <MaterialIcon name="verified" iconSize={16} color={c.blue} /> : null}
              </NativeRow>
            )}
          </ListItem.HeadlineContent>
          {subtitle && actor ? (
            <ListItem.SupportingContent>
              <NativeRow horizontalArrangement={{ spacedBy: 6 }} verticalAlignment="center">
                <NativeImage
                  source={networkImages[actor.network] as number}
                  modifiers={[size(15, 15)]}
                />
                <NativeText color={c.secondary} style={smallText}>
                  {subtitle}
                </NativeText>
              </NativeRow>
            </ListItem.SupportingContent>
          ) : null}
          {supportingValue ? (
            <ListItem.SupportingContent>
              <NativeText color={invalid ? c.error : c.secondary} style={smallText}>
                {value}
              </NativeText>
            </ListItem.SupportingContent>
          ) : null}
          {external || (value !== undefined && !supportingValue) ? (
            <ListItem.TrailingContent>
              {external ? (
                <MaterialIcon name="open_in_new" iconSize={18} color={c.secondary} />
              ) : (
                <NativeText color={invalid ? c.error : c.secondary} style={smallText}>
                  {value}
                </NativeText>
              )}
            </ListItem.TrailingContent>
          ) : null}
        </ListItem>
      </NativeHost>
    </View>
  );
}
export function FormToggle({
  title,
  value,
  onChange,
  disabled = false,
}: {
  title: string;
  value: boolean;
  onChange: (value: boolean) => void;
  disabled?: boolean;
}) {
  return (
    <NativeHost matchContents={{ vertical: true }}>
      <ListItem
        colors={{ containerColor: "transparent" }}
        modifiers={[
          fillMaxWidth(),
          ...(disabled
            ? [alpha(0.38)]
            : [toggleable(value, () => onChange(!value), { role: "switch" })]),
        ]}
      >
        <ListItem.HeadlineContent>
          <NativeText style={regularText}>{title}</NativeText>
        </ListItem.HeadlineContent>
        <ListItem.TrailingContent>
          <Switch value={value} enabled={!disabled} onCheckedChange={onChange} />
        </ListItem.TrailingContent>
      </ListItem>
    </NativeHost>
  );
}
export function FormInput({
  search = false,
  label,
  placeholder,
  value,
  onChange,
}: {
  label: string;
  search?: boolean;
  placeholder: string;
  value: string;
  onChange: (value: string) => void;
}) {
  const state = useNativeState(value),
    c = useFormColors();
  useEffect(() => {
    if (state.get() !== value) state.set(value);
  }, [state, value]);
  return (
    <NativeHost
      matchContents={{ vertical: true }}
      style={{ marginHorizontal: 16, marginVertical: 8 }}
    >
      <OutlinedTextField
        value={state}
        onValueChange={onChange}
        singleLine
        modifiers={[fillMaxWidth()]}
        keyboardOptions={{
          capitalization: "none",
          autoCorrectEnabled: false,
          imeAction: search ? "search" : "done",
        }}
      >
        <OutlinedTextField.Label>
          <NativeText>{label}</NativeText>
        </OutlinedTextField.Label>
        <OutlinedTextField.Placeholder>
          <NativeText>{placeholder}</NativeText>
        </OutlinedTextField.Placeholder>
        {search && value ? (
          <OutlinedTextField.TrailingIcon>
            <IconButton
              onClick={() => {
                state.set("");
                onChange("");
              }}
            >
              <MaterialIcon name="close" label="Clear search" color={c.text} />
            </IconButton>
          </OutlinedTextField.TrailingIcon>
        ) : null}
      </OutlinedTextField>
    </NativeHost>
  );
}
export function EmptyState({
  title,
  description,
  icon = "search",
  loading = false,
}: {
  title: string;
  description: string;
  icon?: "search" | "person-circle-outline" | "warning-outline";
  loading?: boolean;
}) {
  const c = useFormColors();
  return (
    <View
      style={{
        minHeight: 320,
        justifyContent: "center",
        alignItems: "center",
        gap: 12,
        padding: 24,
      }}
    >
      {loading ? (
        <ActivityIndicator accessibilityLabel="Loading" />
      ) : (
        <>
          <Ionicons name={icon} size={48} color={c.secondary} />
          <FormText
            style={{ fontSize: 20, lineHeight: 25, fontWeight: "700", textAlign: "center" }}
          >
            {title}
          </FormText>
          <FormText
            secondary
            style={{ fontSize: 15, lineHeight: 20, textAlign: "center", maxWidth: 260 }}
          >
            {description}
          </FormText>
        </>
      )}
    </View>
  );
}
