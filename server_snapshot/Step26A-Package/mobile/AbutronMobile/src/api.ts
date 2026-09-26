import * as SecureStore from "expo-secure-store";

const API_URL = process.env.EXPO_PUBLIC_API_URL || "https://api.abutronfx.online";
const TOKEN_KEY = "abutron_access_token";

export async function getToken(): Promise<string | null> {
  return SecureStore.getItemAsync(TOKEN_KEY);
}

export async function setToken(token: string): Promise<void> {
  await SecureStore.setItemAsync(TOKEN_KEY, token);
}

export async function clearToken(): Promise<void> {
  await SecureStore.deleteItemAsync(TOKEN_KEY);
}

export async function request<T>(
  path: string,
  options: RequestInit = {},
  withAuth = true
): Promise<T> {
  const token = withAuth ? await getToken() : null;
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...((options.headers as Record<string, string>) || {}),
  };
  if (token) headers.Authorization = `Bearer ${token}`;

  const response = await fetch(`${API_URL}${path}`, {...options, headers});
  const text = await response.text();
  let payload: any = {};
  try { payload = text ? JSON.parse(text) : {}; }
  catch { payload = {detail: text}; }

  if (!response.ok) {
    throw new Error(payload.detail || `Request failed (${response.status})`);
  }
  return payload as T;
}

export async function login(email: string, password: string) {
  const payload = await request<any>(
    "/v1/auth/login",
    {method:"POST", body:JSON.stringify({email,password})},
    false
  );
  await setToken(payload.access_token);
  return payload;
}

export async function register(input: {
  email:string;
  password:string;
  full_name:string;
  phone:string;
  terms_accepted:boolean;
  risk_accepted:boolean;
}) {
  return request<any>(
    "/v1/auth/register",
    {method:"POST", body:JSON.stringify(input)},
    false
  );
}
