import { Nav } from "@/components/layout/Nav";
import { Footer } from "@/components/layout/Footer";
import { Masthead } from "@/components/home/Masthead";
import { Pillars } from "@/components/home/Pillars";
import { Mechanics } from "@/components/home/Mechanics";
import { Architecture } from "@/components/home/Architecture";
import { VsTable } from "@/components/home/VsTable";
import { Deployed } from "@/components/home/Deployed";
import { References } from "@/components/home/References";

export default function Home() {
  return (
    <>
      <Nav />
      <main className="flex flex-col">
        <Masthead />
        <Pillars />
        <Mechanics />
        <Architecture />
        <VsTable />
        <Deployed />
        <References />
      </main>
      <Footer />
    </>
  );
}
