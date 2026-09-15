package main

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/png"
	"math"
	"runtime"
)

const iconSize = 32

var (
	macIconTop    = color.RGBA{230, 133, 87, 255}
	macIconBottom = color.RGBA{158, 69, 43, 255}
)

func parseHex(s string) color.RGBA {
	if len(s) == 7 && s[0] == '#' {
		var r, g, b uint8
		_, _ = fmtSscan(s[1:3], &r)
		_, _ = fmtSscan(s[3:5], &g)
		_, _ = fmtSscan(s[5:7], &b)
		return color.RGBA{r, g, b, 255}
	}
	return color.RGBA{45, 125, 246, 255}
}

func fmtSscan(hx string, out *uint8) (int, error) {
	var v int
	for _, c := range hx {
		v <<= 4
		switch {
		case c >= '0' && c <= '9':
			v += int(c - '0')
		case c >= 'a' && c <= 'f':
			v += int(c-'a') + 10
		case c >= 'A' && c <= 'F':
			v += int(c-'A') + 10
		}
	}
	*out = uint8(v)
	return 1, nil
}

func inRoundRect(x, y, size, r int) bool {
	minp, maxp := 1, size-2
	if x < minp || x > maxp || y < minp || y > maxp {
		return false
	}
	inCorner := func(cx, cy int) bool {
		dx, dy := x-cx, y-cy
		return dx*dx+dy*dy <= r*r
	}
	switch {
	case x < minp+r && y < minp+r:
		return inCorner(minp+r, minp+r)
	case x > maxp-r && y < minp+r:
		return inCorner(maxp-r, minp+r)
	case x < minp+r && y > maxp-r:
		return inCorner(minp+r, maxp-r)
	case x > maxp-r && y > maxp-r:
		return inCorner(maxp-r, maxp-r)
	}
	return true
}

// renderIconPNG: a 32x32 PNG with the same white gauge glyph as the macOS app icon.
func renderIconPNG(bgHex string) []byte {
	img := image.NewRGBA(image.Rect(0, 0, iconSize, iconSize))
	bg := parseHex(bgHex)
	for y := 0; y < iconSize; y++ {
		for x := 0; x < iconSize; x++ {
			if inRoundRect(x, y, iconSize, 7) {
				img.Set(x, y, bg)
			}
		}
	}

	drawGauge(img, color.RGBA{255, 255, 255, 255})

	var buf bytes.Buffer
	_ = png.Encode(&buf, img)
	return buf.Bytes()
}

// renderAppIconPNG is used by the installer and matches the macOS app icon's
// warm Claude-family gradient. The tray itself still uses status colors.
func renderAppIconPNG() []byte {
	img := image.NewRGBA(image.Rect(0, 0, iconSize, iconSize))
	for y := 0; y < iconSize; y++ {
		for x := 0; x < iconSize; x++ {
			if inRoundRect(x, y, iconSize, 6) {
				t := float64(x+y) / float64(2*(iconSize-1))
				img.Set(x, y, color.RGBA{
					lerpByte(macIconTop.R, macIconBottom.R, t),
					lerpByte(macIconTop.G, macIconBottom.G, t),
					lerpByte(macIconTop.B, macIconBottom.B, t), 255,
				})
			}
		}
	}
	drawGauge(img, color.RGBA{255, 255, 255, 255})
	var buf bytes.Buffer
	_ = png.Encode(&buf, img)
	return buf.Bytes()
}

func lerpByte(a, b uint8, t float64) uint8 { return uint8(float64(a) + (float64(b)-float64(a))*t) }

func drawGauge(img *image.RGBA, c color.RGBA) {
	cx, cy, radius := 16.0, 20.0, 7.0
	const start, end = 200.0, 340.0
	var px, py float64
	for i := 0; i <= 28; i++ {
		angle := (start + (end-start)*float64(i)/28) * math.Pi / 180
		x := cx + radius*math.Cos(angle)
		y := cy + radius*math.Sin(angle)
		if i > 0 {
			drawIconLine(img, px, py, x, y, 1.35, c)
		}
		px, py = x, y
	}
	drawIconLine(img, 10.5, 20, 21.5, 20, 1.35, c)
	drawIconLine(img, cx, cy, 18.7, 14.3, 1.35, c)
	drawIconDot(img, cx, cy, 1.5, c)
}

func drawIconLine(img *image.RGBA, x1, y1, x2, y2, width float64, c color.RGBA) {
	steps := int(math.Max(math.Abs(x2-x1), math.Abs(y2-y1))*4) + 1
	for i := 0; i <= steps; i++ {
		t := float64(i) / float64(steps)
		drawIconDot(img, x1+(x2-x1)*t, y1+(y2-y1)*t, width/2, c)
	}
}

func drawIconDot(img *image.RGBA, x, y, radius float64, c color.RGBA) {
	for py := int(y-radius) - 1; py <= int(y+radius)+1; py++ {
		for px := int(x-radius) - 1; px <= int(x+radius)+1; px++ {
			if px >= 0 && px < iconSize && py >= 0 && py < iconSize {
				dx, dy := float64(px)+0.5-x, float64(py)+0.5-y
				if dx*dx+dy*dy <= radius*radius {
					img.Set(px, py, c)
				}
			}
		}
	}
}

// iconBytes: ICO on Windows, PNG elsewhere.
func iconBytes(bgHex string) []byte {
	pngBytes := renderIconPNG(bgHex)
	if runtime.GOOS == "windows" {
		return pngToICO(pngBytes)
	}
	return pngBytes
}

// pngToICO: build ICO (icon) bytes that embed the PNG as-is (Windows Vista+ PNG-compressed icon).
func pngToICO(pngBytes []byte) []byte {
	var buf bytes.Buffer
	// ICONDIR
	_ = binary.Write(&buf, binary.LittleEndian, uint16(0)) // reserved
	_ = binary.Write(&buf, binary.LittleEndian, uint16(1)) // type: icon
	_ = binary.Write(&buf, binary.LittleEndian, uint16(1)) // count
	// ICONDIRENTRY
	buf.WriteByte(iconSize)                                            // width
	buf.WriteByte(iconSize)                                            // height
	buf.WriteByte(0)                                                   // color count
	buf.WriteByte(0)                                                   // reserved
	_ = binary.Write(&buf, binary.LittleEndian, uint16(1))             // planes
	_ = binary.Write(&buf, binary.LittleEndian, uint16(32))            // bit count
	_ = binary.Write(&buf, binary.LittleEndian, uint32(len(pngBytes))) // bytes in res
	_ = binary.Write(&buf, binary.LittleEndian, uint32(6+16))          // image offset
	buf.Write(pngBytes)
	return buf.Bytes()
}
