import sharp from "sharp";

export const runtime = "nodejs";

const MAX_INPUT_BYTES = 32 * 1024 * 1024;
const MAX_INPUT_PIXELS = 40_000_000;

export async function POST(request: Request) {
  const bytes = Buffer.from(await request.arrayBuffer());
  if (bytes.length === 0 || bytes.length > MAX_INPUT_BYTES) {
    return new Response("Invalid PNG size", { status: 400 });
  }

  try {
    const output = await sharp(bytes, { limitInputPixels: MAX_INPUT_PIXELS })
      .flatten({ background: "#ffffff" })
      .removeAlpha()
      .png({ compressionLevel: 9 })
      .toBuffer();
    return new Response(output, {
      headers: {
        "Cache-Control": "no-store",
        "Content-Type": "image/png",
      },
    });
  } catch {
    return new Response("Invalid PNG", { status: 400 });
  }
}
