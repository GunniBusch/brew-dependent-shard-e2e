import { IBM_Plex_Mono, Sora } from "next/font/google";
import "./globals.css";

const sora = Sora({ subsets: ["latin"], variable: "--font-sora" });
const mono = IBM_Plex_Mono({ subsets: ["latin"], weight: ["400", "500", "700"], variable: "--font-plex" });

export const metadata = {
  title: "Dependent Sharding Local Visualizer",
  description: "Local Next.js GUI for Homebrew dependent sharding simulation",
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body className={`${sora.variable} ${mono.variable}`}>{children}</body>
    </html>
  );
}
