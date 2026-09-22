import { createRoot } from "react-dom/client";
import { useState } from "react";
import ListingWorkflow from "../src/features/listings/ListingWorkflow";
import { kitFixture, listingA, listings, workspace } from "./kit-fixtures";
import "../src/styles.css";
const fixture = kitFixture();
Object.assign(window, { kitFixture: fixture });
function Fixture() {
  const [selected, select] = useState(listingA);
  return <main style={{ padding: "24px" }}><ListingWorkflow services={fixture.services} workspace={workspace} listings={listings} listingId={selected} onSelectListing={select} onChanged={() => {}} /></main>;
}
createRoot(document.getElementById("root")!).render(<Fixture />);
