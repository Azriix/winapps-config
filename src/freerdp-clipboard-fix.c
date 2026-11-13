/*
 * Correctif LD_PRELOAD pour le presse-papiers de FreeRDP 3.32.2 (chargé par winapps-freerdp).
 *
 * Images déformées dans Word : le CF_DIB porte la taille en pixels dans ses champs de résolution
 * et une hauteur négative. ClipboardGetData remet 96 ppp et l'ordre de lignes habituel.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define CF_DIB 8
#define DIB_HEADER_SIZE 40      /* BITMAPINFOHEADER */
#define PIXELS_PER_METER 3780   /* 96 points par pouce */

static uint32_t read32(const unsigned char* p)
{
	return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static void write32(unsigned char* p, uint32_t v)
{
	p[0] = (unsigned char)v;
	p[1] = (unsigned char)(v >> 8);
	p[2] = (unsigned char)(v >> 16);
	p[3] = (unsigned char)(v >> 24);
}

static void fix_dib(unsigned char* dib, uint32_t size)
{
	if (size < DIB_HEADER_SIZE || read32(dib) != DIB_HEADER_SIZE)
		return;

	write32(dib + 24, PIXELS_PER_METER); /* biXPelsPerMeter */
	write32(dib + 28, PIXELS_PER_METER); /* biYPelsPerMeter */

	/* Retournement des lignes, seulement si la taille est exactement celle attendue. */
	const int32_t width = (int32_t)read32(dib + 4);
	const int32_t height = (int32_t)read32(dib + 8);
	const unsigned bpp = (unsigned)dib[14] | (unsigned)dib[15] << 8;
	const uint32_t compression = read32(dib + 16);

	if (width <= 0 || height >= 0 || compression != 0 || (bpp != 24 && bpp != 32))
		return;

	const uint64_t rows = (uint64_t)(-(int64_t)height);
	const uint64_t stride = (((uint64_t)width * bpp + 31) / 32) * 4;
	if (DIB_HEADER_SIZE + stride * rows != size)
		return;

	unsigned char* line = malloc(stride);
	if (!line)
		return;

	unsigned char* pixels = dib + DIB_HEADER_SIZE;
	for (uint64_t y = 0; y < rows / 2; y++)
	{
		unsigned char* top = pixels + y * stride;
		unsigned char* bottom = pixels + (rows - 1 - y) * stride;
		memcpy(line, top, stride);
		memcpy(top, bottom, stride);
		memcpy(bottom, line, stride);
	}
	free(line);
	write32(dib + 8, (uint32_t)rows); /* biHeight positif */
}

void* ClipboardGetData(void* clipboard, uint32_t formatId, uint32_t* pSize)
{
	static void* (*real)(void*, uint32_t, uint32_t*);

	if (!real)
		real = (void* (*)(void*, uint32_t, uint32_t*))dlsym(RTLD_NEXT, "ClipboardGetData");

	if (!real)
		return NULL;

	void* data = real(clipboard, formatId, pSize);
	if (data && pSize && formatId == CF_DIB)
		fix_dib(data, *pSize);
	return data;
}
