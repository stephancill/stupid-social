import { useAppTheme } from "./src/components/theme";
import { Platform } from "react-native";
import { NavigationContainer } from "@react-navigation/native";
import { createNativeStackNavigator } from "@react-navigation/native-stack";
import { QueryClientProvider } from "@tanstack/react-query";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { StatusBar } from "expo-status-bar";
import { WebView } from "react-native-webview";
import type { Routes, ScreenProps } from "./src/app/navigation";
import { queryClient } from "./src/app/services";
import { PreviewProvider } from "./src/app/preview";
import { FeedScreen } from "./src/screens/Feed";
import { SettingsScreen, AccountScreen, LoginScreen } from "./src/screens/Accounts";
import {
  SearchScreen,
  ProfileScreen,
  NotificationScreen,
  PostScreen,
} from "./src/screens/Profiles";
import { StoriesScreen } from "./src/screens/Stories";
import { ComposerScreen } from "./src/screens/Composer";
const Stack = createNativeStackNavigator<Routes>();
function Browser({ route }: ScreenProps<"Browser">) {
  return (
    <WebView
      source={{ uri: route.params.url }}
      sharedCookiesEnabled
      thirdPartyCookiesEnabled
      setSupportMultipleWindows={false}
    />
  );
}
export default function App() {
  const theme = useAppTheme();
  return (
    <SafeAreaProvider>
      <QueryClientProvider client={queryClient}>
        <PreviewProvider>
          <NavigationContainer theme={theme}>
            <StatusBar style={theme.dark ? "light" : "dark"} />
            <Stack.Navigator
              screenOptions={{
                headerShadowVisible: false,
                ...(Platform.OS === "ios"
                  ? { headerBackButtonDisplayMode: "minimal", headerTintColor: theme.colors.text }
                  : {}),
              }}
            >
              <Stack.Screen name="Home" component={FeedScreen} options={{ title: "Social" }} />
              <Stack.Screen name="Search" component={SearchScreen} options={{ title: "Search" }} />
              <Stack.Screen
                name="Settings"
                component={SettingsScreen}
                options={{ title: "Settings" }}
              />
              <Stack.Screen name="Account" component={AccountScreen} />
              <Stack.Screen name="Login" component={LoginScreen} options={{ title: "Sign in" }} />
              <Stack.Screen name="Profile" component={ProfileScreen} />
              <Stack.Screen name="Notification" component={NotificationScreen} />
              <Stack.Screen name="Post" component={PostScreen} />
              <Stack.Screen
                name="Stories"
                component={StoriesScreen}
                options={{ headerShown: false, presentation: "fullScreenModal" }}
              />
              <Stack.Screen
                name="Composer"
                component={ComposerScreen}
                options={{ headerShown: false, presentation: "fullScreenModal" }}
              />
              <Stack.Screen
                name="Browser"
                component={Browser}
                options={({ route }) => ({ title: route.params.title })}
              />
            </Stack.Navigator>
          </NavigationContainer>
        </PreviewProvider>
      </QueryClientProvider>
    </SafeAreaProvider>
  );
}
