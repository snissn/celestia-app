package appconsts

import (
	"testing"

	"github.com/celestiaorg/go-square/v3/share"
	"github.com/celestiaorg/rsmt2d"
	"github.com/stretchr/testify/require"
)

func TestDefaultCodec_ReusesSharedLeoRSCodec(t *testing.T) {
	first, ok := DefaultCodec().(*rsmt2d.LeoRSCodec)
	require.True(t, ok)

	second, ok := DefaultCodec().(*rsmt2d.LeoRSCodec)
	require.True(t, ok)

	require.Same(t, first, second)
}

func BenchmarkDefaultCodec_Encode(b *testing.B) {
	data := make([][]byte, 512)
	for i := range data {
		data[i] = make([]byte, share.ShareSize)
		data[i][len(data[i])-1] = byte(i)
	}

	b.Run("fresh-codec", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			_, err := rsmt2d.NewLeoRSCodec().Encode(data)
			require.NoError(b, err)
		}
	})

	b.Run("shared-default", func(b *testing.B) {
		codec := DefaultCodec()
		b.ReportAllocs()
		for b.Loop() {
			_, err := codec.Encode(data)
			require.NoError(b, err)
		}
	})
}
