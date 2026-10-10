import {
  Children,
  createContext,
  useContext,
  Fragment,
  isValidElement,
  useEffect,
  useLayoutEffect,
  type ComponentProps,
  type ReactNode,
} from "react";
import {
  ActivityIndicator,
  KeyboardAvoidingView,
  Text,
  View,
  useWindowDimensions,
} from "react-native";
import { useNavigation } from "@react-navigation/native";
import { useHeaderHeight } from "@react-navigation/elements";
import {
  Host,
  Form,
  Section,
  HStack,
  VStack,
  Text as NativeText,
  Button,
  Toggle,
  TextField,
  Image,
  Spacer,
  RNHostView,
  useNativeState,
  ContentUnavailableView,
  List,
} from "@expo/ui/swift-ui";
import {
  accessibilityLabel,
  buttonStyle,
  disabled as nativeDisabled,
  font,
  foregroundStyle,
  frame,
  padding,
  listRowInsets,
  textInputAutocapitalization,
  autocorrectionDisabled,
  onTapGesture,
  listRowBackground,
  listRowSeparator,
  listStyle,
  listSectionMargins,
  useScrollGeometryChange,
} from "@expo/ui/swift-ui/modifiers";
import { useSocialColors, SocialAvatar, networkImages } from "./social";
import { Image as RNImage } from "react-native";
import type * as Android from "./forms";
const NativeRows = createContext(false);
const InitialSection = createContext(false);

export function useFormColors() {
  const c = useSocialColors();
  return { ...c, page: c.dark ? "#000000" : "#F2F2F7", group: c.dark ? "#1C1C1E" : "#FFFFFF" };
}
export function FormText({
  children,
  secondary = false,
  style,
}: ComponentProps<typeof Android.FormText>) {
  const c = useFormColors();
  return (
    <Text
      style={[
        { color: secondary ? c.secondary : c.text, fontSize: 17, lineHeight: 22, flexShrink: 1 },
        style,
      ]}
    >
      {children}
    </Text>
  );
}
function HostedContent({
  children,
  inset = 32,
  clear = false,
}: {
  children: ReactNode;
  inset?: number;
  clear?: boolean;
}) {
  const { width } = useWindowDimensions();
  return (
    <VStack
      spacing={0}
      modifiers={[
        listRowInsets({ top: 0, bottom: 0, leading: 0, trailing: 0 }),
        ...(clear ? [listRowBackground("#00000000"), listRowSeparator("hidden")] : []),
      ]}
    >
      <RNHostView matchContents>
        <NativeRows.Provider value={false}>
          <View style={{ width: width - inset }}>{children}</View>
        </NativeRows.Provider>
      </RNHostView>
    </VStack>
  );
}
function formChildren(children: ReactNode, clear = false, atTop = false): ReactNode {
  let first = atTop;
  function render(nodes: ReactNode): ReactNode {
    return Children.map(nodes, (child) => {
      if (!isValidElement<{ children?: ReactNode }>(child)) return child;
      if (child.type === Fragment) return render(child.props.children);
      const initial = first;
      first = false;
      return (
        <InitialSection.Provider value={initial}>
          {[FormSection, FormRow, FormToggle, FormInput, EmptyState].includes(
            child.type as never,
          ) ? (
            child
          ) : (
            <HostedContent clear={clear}>{child}</HostedContent>
          )}
        </InitialSection.Provider>
      );
    });
  }
  return render(children);
}
export function FormScreen({
  title,
  children,
  trailing,
  bottom,
  inline = false,
  grouped = true,
  onScroll,
}: ComponentProps<typeof Android.FormScreen>) {
  const navigation = useNavigation(),
    c = useFormColors(),
    headerHeight = useHeaderHeight();
  const search =
    isValidElement<ComponentProps<typeof Android.FormInput>>(bottom) && bottom.props.search
      ? bottom.props
      : undefined;
  const scroll = useScrollGeometryChange(
    onScroll
      ? (g) =>
          onScroll({
            nativeEvent: {
              contentOffset: { x: g.contentOffsetX, y: g.contentOffsetY },
              contentSize: { width: g.contentWidth, height: g.contentHeight },
              layoutMeasurement: { width: g.containerWidth, height: g.containerHeight },
              contentInset: { top: 0, bottom: 0, left: 0, right: 0 },
              zoomScale: 1,
            },
          } as Parameters<NonNullable<typeof onScroll>>[0])
      : undefined,
  );
  useLayoutEffect(() => {
    navigation.setOptions({
      title,
      headerLargeTitle: !inline,
      headerRight: trailing ? () => trailing : undefined,
      headerSearchBarOptions: search
        ? {
            placeholder: "Search",
            placement: "automatic",
            hideWhenScrolling: false,
            hideNavigationBar: false,
            autoCapitalize: "none",
            disableAutoCorrect: true,
            onChangeText: (event: { nativeEvent: { text: string } }) =>
              search.onChange(event.nativeEvent.text),
          }
        : undefined,
    });
  }, [navigation, title, trailing, inline, search?.onChange]);
  const Container = grouped ? Form : List;
  return (
    <KeyboardAvoidingView
      behavior="padding"
      keyboardVerticalOffset={headerHeight}
      style={{ flex: 1, backgroundColor: c.page }}
    >
      <Host style={{ flex: 1 }} colorScheme={c.dark ? "dark" : "light"}>
        <NativeRows.Provider value={true}>
          <Container
            modifiers={[
              ...(!grouped ? [listStyle("insetGrouped")] : []),
              ...(scroll ? [scroll] : []),
            ]}
          >
            {formChildren(children, !grouped, true)}
          </Container>
        </NativeRows.Provider>
      </Host>
      {!search ? bottom : null}
    </KeyboardAvoidingView>
  );
}
export function FormSection({
  title,
  children,
  footer,
  onTitlePress,
}: ComponentProps<typeof Android.FormSection>) {
  const initial = useContext(InitialSection);
  return (
    <Section
      modifiers={initial && !title ? [listSectionMargins({ edges: "top", length: 0 })] : undefined}
      title={onTitlePress ? undefined : title}
      header={
        onTitlePress ? (
          <NativeText modifiers={[onTapGesture(onTitlePress)]}>{title}</NativeText>
        ) : undefined
      }
      footer={footer ? <NativeText>{footer}</NativeText> : undefined}
    >
      {formChildren(children)}
    </Section>
  );
}
export function FormRow({
  actor,
  subtitle,
  verified,
  title,
  value,
  children,
  onPress,
  disabled = false,
  destructive,
  link,
  centered,
  multiline,
  label,
  external,
  invalid,
  plain,
}: ComponentProps<typeof Android.FormRow>) {
  const c = useFormColors(),
    native = useContext(NativeRows);
  const color = destructive ? c.error : onPress && !link && !plain ? c.blue : c.text;
  if (children) {
    const content = (
      <View accessibilityLabel={label} style={{ paddingHorizontal: 16, paddingVertical: 16 }}>
        {children}
      </View>
    );
    return native ? <HostedContent>{content}</HostedContent> : content;
  }
  const content = (
    <HStack
      spacing={8}
      modifiers={[
        frame({ maxWidth: Infinity, minHeight: 20, alignment: centered ? "center" : "leading" }),
        ...(!native ? [padding({ horizontal: 16, vertical: 16 })] : []),
      ]}
    >
      {invalid ? (
        <NativeText modifiers={[foregroundStyle(c.error), font({ size: 10 })]}>●</NativeText>
      ) : null}
      {actor ? (
        <RNHostView matchContents>
          <SocialAvatar actor={actor} size={subtitle ? 44 : 24} />
        </RNHostView>
      ) : null}
      <VStack spacing={4} alignment="leading">
        <HStack spacing={5}>
          <NativeText modifiers={[font({ size: 17 }), foregroundStyle(color)]}>{title}</NativeText>
          {verified ? <Image systemName="checkmark.seal.fill" size={15} color={c.blue} /> : null}
        </HStack>
        {subtitle && actor ? (
          <HStack spacing={4}>
            <RNHostView matchContents>
              <RNImage source={networkImages[actor.network]} style={{ width: 13, height: 13 }} />
            </RNHostView>
            <NativeText modifiers={[font({ size: 15 }), foregroundStyle(c.secondary)]}>
              {subtitle}
            </NativeText>
          </HStack>
        ) : null}
        {multiline && value ? (
          <NativeText modifiers={[foregroundStyle(c.secondary)]}>{value}</NativeText>
        ) : null}
      </VStack>
      {!centered ? <Spacer /> : null}
      {!multiline && value !== undefined ? (
        <NativeText modifiers={[font({ size: link ? 16 : 17 }), foregroundStyle(c.secondary)]}>
          {value}
        </NativeText>
      ) : null}
      {external || link ? (
        <Image
          systemName={external ? "arrow.up.forward.square" : "chevron.right"}
          modifiers={[
            font({ size: external ? 12 : 13, weight: external ? "regular" : "semibold" }),
          ]}
          color={external ? c.text : c.tertiary}
        />
      ) : null}
    </HStack>
  );
  const row = onPress ? (
    <Button
      onPress={onPress}
      modifiers={[
        buttonStyle("plain"),
        nativeDisabled(disabled),
        ...(label ? [accessibilityLabel(label)] : []),
      ]}
    >
      {content}
    </Button>
  ) : (
    content
  );
  return native ? (
    row
  ) : (
    <Host matchContents={{ vertical: true }} colorScheme={c.dark ? "dark" : "light"}>
      {row}
    </Host>
  );
}
export function FormToggle({
  title,
  value,
  onChange,
  disabled = false,
}: ComponentProps<typeof Android.FormToggle>) {
  const native = useContext(NativeRows);
  const toggle = (
    <Toggle
      label={title}
      isOn={value}
      onIsOnChange={onChange}
      modifiers={[
        nativeDisabled(disabled),
        ...(!native ? [padding({ horizontal: 16, vertical: 16 })] : []),
      ]}
    />
  );
  return native ? toggle : <Host matchContents={{ vertical: true }}>{toggle}</Host>;
}
export function FormInput({
  label,
  placeholder,
  value,
  onChange,
}: ComponentProps<typeof Android.FormInput>) {
  const state = useNativeState(value),
    c = useFormColors(),
    native = useContext(NativeRows);
  useEffect(() => {
    if (state.get() !== value) state.set(value);
  }, [state, value]);
  const field = (
    <TextField
      text={state}
      placeholder={placeholder}
      onTextChange={onChange}
      modifiers={[
        accessibilityLabel(label),
        textInputAutocapitalization("never"),
        autocorrectionDisabled(),
      ]}
    />
  );
  return native ? (
    field
  ) : (
    <Host
      matchContents={{ vertical: true }}
      style={{ marginHorizontal: 16, marginVertical: 12 }}
      colorScheme={c.dark ? "dark" : "light"}
    >
      {field}
    </Host>
  );
}
export function EmptyState({
  title,
  description,
  icon = "search",
  loading,
}: ComponentProps<typeof Android.EmptyState>) {
  const native = useContext(NativeRows);
  if (loading) {
    const spinner = <ActivityIndicator style={{ height: 320 }} accessibilityLabel="Loading" />;
    return native ? <HostedContent clear>{spinner}</HostedContent> : spinner;
  }
  const content = (
    <ContentUnavailableView
      title={title}
      description={description}
      systemImage={
        icon === "person-circle-outline"
          ? "person.crop.circle"
          : icon === "warning-outline"
            ? "exclamationmark.triangle"
            : "magnifyingglass"
      }
      modifiers={[
        frame({ minHeight: 320 }),
        listRowBackground("#00000000"),
        listRowSeparator("hidden"),
      ]}
    />
  );
  return native ? (
    <Section modifiers={[listSectionMargins({ edges: "top", length: 0 })]}>{content}</Section>
  ) : (
    <Host style={{ minHeight: 320, height: 320 }}>{content}</Host>
  );
}
