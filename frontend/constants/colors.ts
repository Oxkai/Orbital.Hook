export const colors = {
  green: {
    hex: "#8AE06C",
    rgb: "rgb(138, 224, 108)",
    hsl: "hsl(104.5, 65.2%, 65.1%)",
  },
  red: {
    hex: "#F56868",
    rgb: "rgb(245, 104, 104)",
    hsl: "hsl(0, 87.6%, 68.4%)",
  },
  purple: {
    hex: "#A770FF",
    rgb: "rgb(167, 112, 255)",
    hsl: "hsl(259.4, 100%, 74.5%)",
  },
  yellow: {
    hex: "#F1DF38",
    rgb: "rgb(241, 223, 56)",
    hsl: "hsl(54.2, 85.9%, 58.2%)",
  },

  black: {
    hex: "#0A0A0A",
    rgb: "rgb(10, 10, 10)",
    hsl: "hsl(0, 0%, 3.9%)",
  },
  white: {
    hex: "#FFFFFF",
    rgb: "rgb(255, 255, 255)",
    hsl: "hsl(0, 0%, 100%)",
  },

  grey: {
    1: { hex: "#161616", rgb: "rgb(22, 22, 22)", hsl: "hsl(0, 0%, 8.6%)" },
    2: { hex: "#1E1E1E", rgb: "rgb(30, 30, 30)", hsl: "hsl(0, 0%, 11.8%)" },
    3: { hex: "#232323", rgb: "rgb(35, 35, 35)", hsl: "hsl(0, 0%, 13.7%)" },
    4: { hex: "#313131", rgb: "rgb(49, 49, 49)", hsl: "hsl(0, 0%, 19.2%)" },
    5: { hex: "#454545", rgb: "rgb(69, 69, 69)", hsl: "hsl(0, 0%, 27.1%)" },
    6: { hex: "#757575", rgb: "rgb(117, 117, 117)", hsl: "hsl(0, 0%, 45.9%)" },
    7: { hex: "#E6E6E6", rgb: "rgb(230, 230, 230)", hsl: "hsl(0, 0%, 90.2%)" },
    8: { hex: "#F5F5F5", rgb: "rgb(245, 245, 245)", hsl: "hsl(0, 0%, 96.1%)" },
  },
} as const;

export type ThemeName = "dark" | "light";

type ThemePalette = {
  success: string;
  error: string;
  warning: string;
  info: string;
  accent: string;
  bg: string;
  surface1: string;
  surface2: string;
  surface3: string;
  surface4: string;
  border: string;
  borderSubtle: string;
  textPrimary: string;
  textSecondary: string;
  textMuted: string;
};

export const themePalettes: Record<ThemeName, ThemePalette> = {
  dark: {
    success: colors.green.hex,
    error: colors.red.hex,
    warning: colors.yellow.hex,
    info: colors.purple.hex,
    accent: colors.purple.hex,
    bg: "#0A0A0A",
    surface1: "#161616",
    surface2: "#1E1E1E",
    surface3: "#232323",
    surface4: "#313131",
    border: "#313131",
    borderSubtle: "#232323",
    textPrimary: "#FFFFFF",
    textSecondary: "#E6E6E6",
    textMuted: "#757575",
  },
  light: {
    success: colors.green.hex,
    error: colors.red.hex,
    warning: colors.yellow.hex,
    info: "#7E5CF2",
    accent: "#7E5CF2",
    bg: "#F6F6F6",
    surface1: "#FFFFFF",
    surface2: "#F7F7F7",
    surface3: "#E6E6E6",
    surface4: "#D0D0D0",
    border: "#E7E7E7",
    borderSubtle: "#E0E0E0",
    textPrimary: "#010101",
    textSecondary: "#303030",
    textMuted: "#797979",
  },
};

export function getThemeCssVariables(theme: ThemeName): Record<string, string> {
  const palette = themePalettes[theme];
  return {
    "--color-success": palette.success,
    "--color-error": palette.error,
    "--color-warning": palette.warning,
    "--color-info": palette.info,
    "--color-accent": palette.accent,
    "--color-bg": palette.bg,
    "--color-surface-1": palette.surface1,
    "--color-surface-2": palette.surface2,
    "--color-surface-3": palette.surface3,
    "--color-surface-4": palette.surface4,
    "--color-border": palette.border,
    "--color-border-subtle": palette.borderSubtle,
    "--color-text-primary": palette.textPrimary,
    "--color-text-secondary": palette.textSecondary,
    "--color-text-muted": palette.textMuted,
  };
}

export const color = {
  success: "var(--color-success)",
  error: "var(--color-error)",
  warning: "var(--color-warning)",
  info: "var(--color-info)",

  bg: "var(--color-bg)",
  surface1: "var(--color-surface-1)",
  surface2: "var(--color-surface-2)",
  surface3: "var(--color-surface-3)",
  surface4: "var(--color-surface-4)",

  border: "var(--color-border)",
  borderSubtle: "var(--color-border-subtle)",

  textPrimary: "var(--color-text-primary)",
  textSecondary: "var(--color-text-secondary)",
  textMuted: "var(--color-text-muted)",

  accent: "var(--color-accent)",
} as const;

export type ColorKey = keyof typeof color;
