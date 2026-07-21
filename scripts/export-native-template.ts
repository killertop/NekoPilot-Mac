import { BUILT_IN_TEMPLATE_OBJECTS } from "../src/config/templates/generated.ts";

const output = new URL(
  "../native/Sources/NekoPilotCore/Resources/base-config.json",
  import.meta.url,
);

await Deno.writeTextFile(
  output,
  `${JSON.stringify(BUILT_IN_TEMPLATE_OBJECTS.mixed, null, 2)}\n`,
);
