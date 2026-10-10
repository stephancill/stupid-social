export function parseCookies({ header }: { header: string }): Record<string, string> {
  return Object.fromEntries(
    header.split(";").flatMap((part) => {
      const position = part.indexOf("=");
      return position < 1
        ? []
        : [[part.slice(0, position).trim(), part.slice(position + 1).trim()]];
    }),
  );
}

export function selectedResponseCookies({
  headers,
  selected,
}: {
  headers: Pick<Headers, "get"> & { getSetCookie?: () => string[] };
  selected: string[];
}) {
  const values =
    headers.getSetCookie?.() ?? (headers.get("set-cookie") ?? "").split(/,\s*(?=[^;,\s]+=)/);
  const result: Record<string, string> = {};
  for (const line of values) {
    const first = line.split(";", 1)[0]!,
      index = first.indexOf("=");
    if (index > 0 && selected.includes(first.slice(0, index).trim()))
      result[first.slice(0, index).trim()] = first.slice(index + 1);
  }
  return result;
}
