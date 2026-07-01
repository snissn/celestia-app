package app

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"cosmossdk.io/log"
	storetypes "cosmossdk.io/store/types"
	abci "github.com/cometbft/cometbft/abci/types"
	tmproto "github.com/cometbft/cometbft/proto/tendermint/types"
	tmdb "github.com/cosmos/cosmos-db"
	"github.com/cosmos/cosmos-sdk/baseapp"
	sdk "github.com/cosmos/cosmos-sdk/types"
	authtypes "github.com/cosmos/cosmos-sdk/x/auth/types"
	"github.com/stretchr/testify/require"
)

type orderedRootProbeTestAppOptions map[string]any

func (opts orderedRootProbeTestAppOptions) Get(key string) any {
	return opts[key]
}

type orderedRootProbeTestProvider map[int64]*storetypes.CommitInfo

func (provider orderedRootProbeTestProvider) GetCommitInfo(height int64) (*storetypes.CommitInfo, error) {
	info, ok := provider[height]
	if !ok {
		return nil, fmt.Errorf("missing commit info for height %d", height)
	}
	return info, nil
}

type orderedRootProbeNoopWriter struct{}

func (orderedRootProbeNoopWriter) Write(p []byte) (int, error) {
	return len(p), nil
}

func TestOrderedRootProbeSummarizesChangeSetAndCommitIDs(t *testing.T) {
	dir := t.TempDir()
	provider := orderedRootProbeTestProvider{
		1: {
			Version: 1,
			StoreInfos: []storetypes.StoreInfo{
				{Name: "bank", CommitId: storetypes.CommitID{Version: 1, Hash: []byte{0x01}}},
			},
		},
		2: {
			Version: 2,
			StoreInfos: []storetypes.StoreInfo{
				{Name: "bank", CommitId: storetypes.CommitID{Version: 2, Hash: []byte{0x02}}},
				{Name: "staking", CommitId: storetypes.CommitID{Version: 2, Hash: []byte{0x03}}},
			},
		},
	}
	probe, err := newOrderedRootProbe(provider, dir, newOrderedRootProbeMetrics())
	require.NoError(t, err)

	ctx := sdk.NewContext(nil, tmproto.Header{Height: 2}, false, log.NewNopLogger())
	err = probe.ListenCommit(ctx, abci.ResponseCommit{}, []*storetypes.StoreKVPair{
		{StoreKey: "bank", Key: []byte("b"), Value: []byte("vv")},
		{StoreKey: "bank", Key: []byte("a"), Value: []byte("v")},
		{StoreKey: "bank", Delete: true, Key: []byte("a")},
		{StoreKey: "staking", Key: []byte("c"), Value: []byte("vvv")},
	})
	require.NoError(t, err)
	require.NoError(t, probe.Close())

	records := readOrderedRootProbeRecords(t, filepath.Join(dir, orderedRootProbeJSONL))
	require.Len(t, records, 2)
	byStore := map[string]orderedRootProbeRecord{}
	for _, record := range records {
		byStore[record.Store] = record
	}

	bank := byStore["bank"]
	require.Equal(t, int64(2), bank.Height)
	require.Equal(t, int64(2), bank.CommitVersion)
	require.Equal(t, int64(1), bank.BaseCommitVersion)
	require.Equal(t, "01", bank.BaseCommitHash)
	require.Equal(t, int64(2), bank.NewCommitVersion)
	require.Equal(t, "02", bank.NewCommitHash)
	require.Equal(t, 2, bank.LogicalSets)
	require.Equal(t, 1, bank.LogicalDeletes)
	require.Equal(t, 3, bank.KeyBytes)
	require.Equal(t, 3, bank.ValueBytes)
	require.Equal(t, 6, bank.BytesTotal)
	require.Equal(t, 1, bank.DuplicateKeys)
	require.False(t, bank.SortedInput)
	require.Equal(t, 1, bank.Tombstones)
	require.Equal(t, []string{"duplicate_collapse_required", "unsorted_delta"}, bank.FallbackReasons)
	require.True(t, bank.DescriptorComplete)

	staking := byStore["staking"]
	require.Equal(t, int64(2), staking.NewCommitVersion)
	require.Equal(t, "03", staking.NewCommitHash)
	require.Empty(t, staking.BaseCommitHash)
	require.Equal(t, []string{"base_commit_id_missing"}, staking.FallbackReasons)
	require.False(t, staking.DescriptorComplete)
}

func TestOrderedRootProbeRejectsNilCommitInfo(t *testing.T) {
	probe, err := newOrderedRootProbe(orderedRootProbeTestProvider{2: nil}, "", newOrderedRootProbeMetrics())
	require.NoError(t, err)

	_, _, err = probe.commitInfoByStore(2)
	require.ErrorContains(t, err, "missing commit info for height 2")
}

func TestOrderedRootProbeCloseIsIdempotentAndPrivate(t *testing.T) {
	dir := t.TempDir()
	probe, err := newOrderedRootProbe(orderedRootProbeTestProvider{}, dir, newOrderedRootProbeMetrics())
	require.NoError(t, err)

	require.NoError(t, probe.Close())
	require.NoError(t, probe.Close())

	info, err := os.Stat(filepath.Join(dir, orderedRootProbeJSONL))
	require.NoError(t, err)
	require.Zero(t, info.Mode().Perm()&0o077)
}

func TestNewRegistersOrderedRootProbeWhenEnabled(t *testing.T) {
	got := New(
		log.NewNopLogger(),
		tmdb.NewMemDB(),
		orderedRootProbeNoopWriter{},
		time.Second,
		orderedRootProbeTestAppOptions{
			orderedRootProbeEnabledKey: true,
			orderedRootProbeKeysKey:    []string{authtypes.StoreKey},
		},
	)

	require.True(t, got.CommitMultiStore().ListeningEnabled(got.GetKey(authtypes.StoreKey)))
}

func TestNewRejectsOrderedRootProbeWithStreamingPlugin(t *testing.T) {
	pluginKey := fmt.Sprintf(
		"%s.%s.%s",
		baseapp.StreamingTomlKey,
		baseapp.StreamingABCITomlKey,
		baseapp.StreamingABCIPluginTomlKey,
	)
	appOptions := orderedRootProbeTestAppOptions{
		orderedRootProbeEnabledKey: true,
		baseapp.StreamingTomlKey: map[string]any{
			baseapp.StreamingABCITomlKey: map[string]any{},
		},
		pluginKey: "/definitely/not/a/streaming-plugin",
	}

	defer func() {
		recovered := recover()
		require.NotNil(t, recovered, "expected ordered-root probe and streaming plugin conflict to panic")
		require.Contains(t, fmt.Sprint(recovered), "failed to register ordered-root probe")
		require.Contains(t, fmt.Sprint(recovered), "cannot run alongside configured ABCI streaming plugins")
	}()

	_ = New(log.NewNopLogger(), tmdb.NewMemDB(), orderedRootProbeNoopWriter{}, time.Second, appOptions)
}

func readOrderedRootProbeRecords(t *testing.T, path string) []orderedRootProbeRecord {
	t.Helper()
	data, err := os.ReadFile(path)
	require.NoError(t, err)
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	records := make([]orderedRootProbeRecord, 0, len(lines))
	for _, line := range lines {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var record orderedRootProbeRecord
		require.NoError(t, json.Unmarshal([]byte(line), &record))
		records = append(records, record)
	}
	return records
}

var _ io.Writer = orderedRootProbeNoopWriter{}
