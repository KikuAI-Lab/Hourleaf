import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Hourleaf App Store Screenshots",
  description: "Design and export localized Hourleaf App Store screenshots.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body>{children}</body>
    </html>
  );
}
