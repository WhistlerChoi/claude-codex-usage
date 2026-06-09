package main

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/png"
	"runtime"

	"golang.org/x/image/draw"
	"golang.org/x/image/font"
	"golang.org/x/image/font/basicfont"
	"golang.org/x/image/math/fixed"
)

const iconSize = 32

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

// renderIconPNG: a 32x32 PNG with a rounded-rectangle background and white digits.
func renderIconPNG(text, bgHex string) []byte {
	img := image.NewRGBA(image.Rect(0, 0, iconSize, iconSize))
	bg := parseHex(bgHex)
	for y := 0; y < iconSize; y++ {
		for x := 0; x < iconSize; x++ {
			if inRoundRect(x, y, iconSize, 7) {
				img.Set(x, y, bg)
			}
		}
	}

	// draw the digits with a small bitmap font, then scale up and center them
	tw := 7 * len(text)
	th := 13
	tmp := image.NewRGBA(image.Rect(0, 0, tw, th))
	d := &font.Drawer{
		Dst:  tmp,
		Src:  image.NewUniform(color.White),
		Face: basicfont.Face7x13,
		Dot:  fixed.P(0, 11),
	}
	d.DrawString(text)

	maxW, maxH := float64(iconSize-6), float64(iconSize-8)
	s := maxW / float64(tw)
	if sy := maxH / float64(th); sy < s {
		s = sy
	}
	dw, dh := int(float64(tw)*s), int(float64(th)*s)
	x0, y0 := (iconSize-dw)/2, (iconSize-dh)/2
	draw.ApproxBiLinear.Scale(img, image.Rect(x0, y0, x0+dw, y0+dh), tmp, tmp.Bounds(), draw.Over, nil)

	var buf bytes.Buffer
	_ = png.Encode(&buf, img)
	return buf.Bytes()
}

// iconBytes: ICO on Windows, PNG elsewhere.
func iconBytes(text, bgHex string) []byte {
	pngBytes := renderIconPNG(text, bgHex)
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
	buf.WriteByte(iconSize) // width
	buf.WriteByte(iconSize) // height
	buf.WriteByte(0)        // color count
	buf.WriteByte(0)        // reserved
	_ = binary.Write(&buf, binary.LittleEndian, uint16(1))               // planes
	_ = binary.Write(&buf, binary.LittleEndian, uint16(32))              // bit count
	_ = binary.Write(&buf, binary.LittleEndian, uint32(len(pngBytes)))   // bytes in res
	_ = binary.Write(&buf, binary.LittleEndian, uint32(6+16))            // image offset
	buf.Write(pngBytes)
	return buf.Bytes()
}
