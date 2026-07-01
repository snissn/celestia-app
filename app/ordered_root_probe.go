package app

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"expvar"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	storetypes "cosmossdk.io/store/types"
	abci "github.com/cometbft/cometbft/abci/types"
	"github.com/cosmos/cosmos-sdk/baseapp"
	servertypes "github.com/cosmos/cosmos-sdk/server/types"
	sdk "github.com/cosmos/cosmos-sdk/types"
	"github.com/spf13/cast"
)

const (
	orderedRootProbeEnabledEnv = "CELESTIA_TREEDB_ORDERED_ROOT_PROBE"
	orderedRootProbeDirEnv     = "CELESTIA_TREEDB_ORDERED_ROOT_PROBE_DIR"
	orderedRootProbeKeysEnv    = "CELESTIA_TREEDB_ORDERED_ROOT_PROBE_KEYS"

	orderedRootProbeEnabledKey = "treedb.ordered-root-probe.enabled"
	orderedRootProbeDirKey     = "treedb.ordered-root-probe.dir"
	orderedRootProbeKeysKey    = "treedb.ordered-root-probe.keys"

	orderedRootProbeJSONL = "ordered_root_probe.jsonl"
)

var _ storetypes.ABCIListener = (*orderedRootProbe)(nil)

type orderedRootProbeCommitInfoProvider interface {
	GetCommitInfo(int64) (*storetypes.CommitInfo, error)
}

type orderedRootProbeConfig struct {
	Enabled   bool
	OutputDir string
	Keys      []string
}

type orderedRootProbe struct {
	commitInfoProvider orderedRootProbeCommitInfoProvider
	metrics            *orderedRootProbeMetrics

	mu      sync.Mutex
	encoder *json.Encoder
	closer  func() error
}

type orderedRootProbeRecord struct {
	Height             int64    `json:"height"`
	CommitVersion      int64    `json:"commit_version"`
	Store              string   `json:"store"`
	BaseCommitVersion  int64    `json:"base_commit_version,omitempty"`
	BaseCommitHash     string   `json:"base_commit_hash,omitempty"`
	NewCommitVersion   int64    `json:"new_commit_version,omitempty"`
	NewCommitHash      string   `json:"new_commit_hash,omitempty"`
	LogicalSets        int      `json:"logical_sets"`
	LogicalDeletes     int      `json:"logical_deletes"`
	KeyBytes           int      `json:"key_bytes"`
	ValueBytes         int      `json:"value_bytes"`
	BytesTotal         int      `json:"bytes_total"`
	DuplicateKeys      int      `json:"duplicate_keys"`
	SortedInput        bool     `json:"sorted_input"`
	Tombstones         int      `json:"tombstones"`
	MaxKeyBytes        int      `json:"max_key_bytes"`
	MaxValueBytes      int      `json:"max_value_bytes"`
	DescriptorComplete bool     `json:"descriptor_complete"`
	BuildNs            int64    `json:"build_ns"`
	FallbackReasons    []string `json:"fallback_reasons,omitempty"`
}

type orderedRootProbeStoreSummary struct {
	logicalSets    int
	logicalDeletes int
	keyBytes       int
	valueBytes     int
	duplicateKeys  int
	sortedInput    bool
	tombstones     int
	maxKeyBytes    int
	maxValueBytes  int
	seenKeys       map[string]struct{}
	lastKey        []byte
}

func registerOrderedRootProbe(
	baseApp *baseapp.BaseApp,
	appOpts servertypes.AppOptions,
	keys map[string]*storetypes.KVStoreKey,
) error {
	cfg := orderedRootProbeConfigFromOptions(appOpts)
	if !cfg.Enabled {
		return nil
	}

	if streamingPluginConfigured(appOpts) {
		return fmt.Errorf("ordered-root probe cannot run alongside configured ABCI streaming plugins")
	}

	provider, ok := baseApp.CommitMultiStore().(orderedRootProbeCommitInfoProvider)
	if !ok {
		defaultOrderedRootProbeMetrics.addFallback("commit_info_unavailable")
		return fmt.Errorf("commit multi-store does not expose GetCommitInfo")
	}

	probe, err := newOrderedRootProbe(provider, cfg.OutputDir, defaultOrderedRootProbeMetrics)
	if err != nil {
		defaultOrderedRootProbeMetrics.addFallback("probe_error")
		return err
	}

	baseApp.CommitMultiStore().AddListeners(orderedRootProbeStoreKeys(cfg.Keys, keys))
	baseApp.SetStreamingManager(storetypes.StreamingManager{
		ABCIListeners: []storetypes.ABCIListener{probe},
	})
	return nil
}

func orderedRootProbeConfigFromOptions(appOpts servertypes.AppOptions) orderedRootProbeConfig {
	enabled := cast.ToBool(os.Getenv(orderedRootProbeEnabledEnv))
	if v := appOpts.Get(orderedRootProbeEnabledKey); v != nil {
		enabled = cast.ToBool(v)
	}

	outputDir := strings.TrimSpace(os.Getenv(orderedRootProbeDirEnv))
	if v := appOpts.Get(orderedRootProbeDirKey); v != nil {
		outputDir = strings.TrimSpace(cast.ToString(v))
	}

	keys := splitOrderedRootProbeKeys(os.Getenv(orderedRootProbeKeysEnv))
	if v := appOpts.Get(orderedRootProbeKeysKey); v != nil {
		keys = cast.ToStringSlice(v)
	}
	if len(keys) == 0 {
		keys = []string{"*"}
	}

	return orderedRootProbeConfig{
		Enabled:   enabled,
		OutputDir: outputDir,
		Keys:      keys,
	}
}

func splitOrderedRootProbeKeys(raw string) []string {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	keys := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part != "" {
			keys = append(keys, part)
		}
	}
	return keys
}

func streamingPluginConfigured(appOpts servertypes.AppOptions) bool {
	streamingCfg := cast.ToStringMap(appOpts.Get(baseapp.StreamingTomlKey))
	for service := range streamingCfg {
		pluginKey := fmt.Sprintf("%s.%s.%s", baseapp.StreamingTomlKey, service, baseapp.StreamingABCIPluginTomlKey)
		if strings.TrimSpace(cast.ToString(appOpts.Get(pluginKey))) != "" {
			return true
		}
	}
	return false
}

func orderedRootProbeStoreKeys(names []string, keys map[string]*storetypes.KVStoreKey) []storetypes.StoreKey {
	if slices.Contains(names, "*") {
		storeKeys := make([]storetypes.StoreKey, 0, len(keys))
		for _, key := range keys {
			storeKeys = append(storeKeys, key)
		}
		sort.SliceStable(storeKeys, func(i, j int) bool {
			return storeKeys[i].Name() < storeKeys[j].Name()
		})
		return storeKeys
	}

	storeKeys := make([]storetypes.StoreKey, 0, len(names))
	for _, name := range names {
		if key, ok := keys[name]; ok {
			storeKeys = append(storeKeys, key)
		}
	}
	sort.SliceStable(storeKeys, func(i, j int) bool {
		return storeKeys[i].Name() < storeKeys[j].Name()
	})
	return storeKeys
}

func newOrderedRootProbe(
	provider orderedRootProbeCommitInfoProvider,
	outputDir string,
	metrics *orderedRootProbeMetrics,
) (*orderedRootProbe, error) {
	if metrics == nil {
		metrics = defaultOrderedRootProbeMetrics
	}

	var encoder *json.Encoder
	var closer func() error
	if outputDir != "" {
		if err := os.MkdirAll(outputDir, 0o700); err != nil {
			return nil, fmt.Errorf("create ordered-root probe dir: %w", err)
		}
		f, err := os.OpenFile(filepath.Join(outputDir, orderedRootProbeJSONL), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
		if err != nil {
			return nil, fmt.Errorf("open ordered-root probe output: %w", err)
		}
		encoder = json.NewEncoder(f)
		closer = f.Close
	}

	return &orderedRootProbe{
		commitInfoProvider: provider,
		metrics:            metrics,
		encoder:            encoder,
		closer:             closer,
	}, nil
}

func (p *orderedRootProbe) ListenFinalizeBlock(context.Context, abci.RequestFinalizeBlock, abci.ResponseFinalizeBlock) error {
	return nil
}

func (p *orderedRootProbe) ListenCommit(ctx context.Context, _ abci.ResponseCommit, changeSet []*storetypes.StoreKVPair) error {
	start := time.Now()
	height := sdk.UnwrapSDKContext(ctx).BlockHeight()
	p.metrics.commitsSeen.Add(1)

	if len(changeSet) == 0 {
		p.metrics.addFallback("no_changeset")
		return nil
	}

	currentInfo, currentByStore, currentErr := p.commitInfoByStore(height)
	baseInfo, baseByStore, baseErr := p.commitInfoByStore(height - 1)
	if currentErr != nil {
		p.metrics.addFallback("commit_info_unavailable")
	}
	if baseErr != nil {
		p.metrics.addFallback("base_commit_id_missing")
	}

	summaries := orderedRootProbeSummaries(changeSet)
	stores := make([]string, 0, len(summaries))
	for store := range summaries {
		stores = append(stores, store)
	}
	sort.Strings(stores)

	buildNs := time.Since(start).Nanoseconds()
	for _, store := range stores {
		summary := summaries[store]
		record := orderedRootProbeRecord{
			Height:         height,
			CommitVersion:  commitInfoVersion(currentInfo, height),
			Store:          store,
			LogicalSets:    summary.logicalSets,
			LogicalDeletes: summary.logicalDeletes,
			KeyBytes:       summary.keyBytes,
			ValueBytes:     summary.valueBytes,
			BytesTotal:     summary.keyBytes + summary.valueBytes,
			DuplicateKeys:  summary.duplicateKeys,
			SortedInput:    summary.sortedInput,
			Tombstones:     summary.tombstones,
			MaxKeyBytes:    summary.maxKeyBytes,
			MaxValueBytes:  summary.maxValueBytes,
			BuildNs:        buildNs,
		}

		if currentErr != nil {
			record.FallbackReasons = append(record.FallbackReasons, "commit_info_unavailable")
		} else if id, ok := currentByStore[store]; ok && !id.IsZero() {
			record.NewCommitVersion = id.Version
			record.NewCommitHash = hex.EncodeToString(id.Hash)
		} else {
			record.FallbackReasons = append(record.FallbackReasons, "store_commit_id_missing")
		}

		if baseErr != nil {
			record.FallbackReasons = append(record.FallbackReasons, "base_commit_id_missing")
		} else if id, ok := baseByStore[store]; ok && !id.IsZero() {
			record.BaseCommitVersion = id.Version
			record.BaseCommitHash = hex.EncodeToString(id.Hash)
		} else if baseInfo != nil {
			record.FallbackReasons = append(record.FallbackReasons, "base_commit_id_missing")
		}

		if summary.duplicateKeys > 0 {
			record.FallbackReasons = append(record.FallbackReasons, "duplicate_collapse_required")
		}
		if !summary.sortedInput {
			record.FallbackReasons = append(record.FallbackReasons, "unsorted_delta")
		}

		record.FallbackReasons = uniqueStrings(record.FallbackReasons)
		record.DescriptorComplete = record.NewCommitHash != "" && record.BaseCommitHash != ""
		p.recordSummary(record)
	}

	return nil
}

func (p *orderedRootProbe) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()

	if p.closer == nil {
		return nil
	}
	closer := p.closer
	p.encoder = nil
	p.closer = nil
	return closer()
}

func (p *orderedRootProbe) commitInfoByStore(height int64) (*storetypes.CommitInfo, map[string]storetypes.CommitID, error) {
	if height <= 0 {
		return nil, nil, fmt.Errorf("height %d has no commit info", height)
	}
	info, err := p.commitInfoProvider.GetCommitInfo(height)
	if err != nil {
		return nil, nil, err
	}
	if info == nil {
		return nil, nil, fmt.Errorf("missing commit info for height %d", height)
	}
	byStore := make(map[string]storetypes.CommitID, len(info.StoreInfos))
	for _, storeInfo := range info.StoreInfos {
		byStore[storeInfo.Name] = storeInfo.CommitId
	}
	return info, byStore, nil
}

func (p *orderedRootProbe) recordSummary(record orderedRootProbeRecord) {
	p.metrics.storeDescriptorsSeen.Add(1)
	p.metrics.logicalSetsTotal.Add(int64(record.LogicalSets))
	p.metrics.logicalDeletesTotal.Add(int64(record.LogicalDeletes))
	p.metrics.duplicateKeysTotal.Add(int64(record.DuplicateKeys))
	if !record.SortedInput {
		p.metrics.unsortedInputsTotal.Add(1)
	}
	p.metrics.bytesTotal.Add(int64(record.BytesTotal))
	p.metrics.buildNsTotal.Add(record.BuildNs)
	for _, reason := range record.FallbackReasons {
		p.metrics.addFallback(reason)
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	if p.encoder == nil {
		return
	}
	if err := p.encoder.Encode(record); err != nil {
		p.metrics.addFallback("probe_error")
	}
}

func orderedRootProbeSummaries(changeSet []*storetypes.StoreKVPair) map[string]*orderedRootProbeStoreSummary {
	summaries := make(map[string]*orderedRootProbeStoreSummary)
	for _, pair := range changeSet {
		if pair == nil {
			continue
		}
		summary := summaries[pair.StoreKey]
		if summary == nil {
			summary = &orderedRootProbeStoreSummary{
				sortedInput: true,
				seenKeys:    make(map[string]struct{}),
			}
			summaries[pair.StoreKey] = summary
		}
		summary.observe(pair)
	}
	return summaries
}

func (s *orderedRootProbeStoreSummary) observe(pair *storetypes.StoreKVPair) {
	if pair.Delete {
		s.logicalDeletes++
		s.tombstones++
	} else {
		s.logicalSets++
	}

	keyLen := len(pair.Key)
	valueLen := len(pair.Value)
	s.keyBytes += keyLen
	s.valueBytes += valueLen
	if keyLen > s.maxKeyBytes {
		s.maxKeyBytes = keyLen
	}
	if valueLen > s.maxValueBytes {
		s.maxValueBytes = valueLen
	}
	if s.lastKey != nil && bytes.Compare(s.lastKey, pair.Key) > 0 {
		s.sortedInput = false
	}
	s.lastKey = pair.Key

	key := string(pair.Key)
	if _, ok := s.seenKeys[key]; ok {
		s.duplicateKeys++
		return
	}
	s.seenKeys[key] = struct{}{}
}

func commitInfoVersion(info *storetypes.CommitInfo, fallback int64) int64 {
	if info == nil || info.Version == 0 {
		return fallback
	}
	return info.Version
}

func uniqueStrings(values []string) []string {
	if len(values) < 2 {
		return values
	}
	sort.Strings(values)
	out := values[:0]
	var last string
	for i, value := range values {
		if i == 0 || value != last {
			out = append(out, value)
			last = value
		}
	}
	return out
}

type orderedRootProbeMetrics struct {
	commitsSeen          *expvar.Int
	storeDescriptorsSeen *expvar.Int
	logicalSetsTotal     *expvar.Int
	logicalDeletesTotal  *expvar.Int
	duplicateKeysTotal   *expvar.Int
	unsortedInputsTotal  *expvar.Int
	bytesTotal           *expvar.Int
	buildNsTotal         *expvar.Int

	mu        sync.Mutex
	fallbacks map[string]*expvar.Int
}

var defaultOrderedRootProbeMetrics = newOrderedRootProbeMetrics()

func newOrderedRootProbeMetrics() *orderedRootProbeMetrics {
	return &orderedRootProbeMetrics{
		commitsSeen:          expvarInt("treedb.celestia.ordered_root_probe.commits_seen"),
		storeDescriptorsSeen: expvarInt("treedb.celestia.ordered_root_probe.store_descriptors_seen"),
		logicalSetsTotal:     expvarInt("treedb.celestia.ordered_root_probe.logical_sets_total"),
		logicalDeletesTotal:  expvarInt("treedb.celestia.ordered_root_probe.logical_deletes_total"),
		duplicateKeysTotal:   expvarInt("treedb.celestia.ordered_root_probe.duplicate_keys_total"),
		unsortedInputsTotal:  expvarInt("treedb.celestia.ordered_root_probe.unsorted_inputs_total"),
		bytesTotal:           expvarInt("treedb.celestia.ordered_root_probe.bytes_total"),
		buildNsTotal:         expvarInt("treedb.celestia.ordered_root_probe.build_ns_total"),
		fallbacks:            make(map[string]*expvar.Int),
	}
}

func (m *orderedRootProbeMetrics) addFallback(reason string) {
	reason = sanitizeOrderedRootProbeReason(reason)
	m.mu.Lock()
	counter := m.fallbacks[reason]
	if counter == nil {
		counter = expvarInt("treedb.celestia.ordered_root_probe.fallback.reason." + reason + ".count_total")
		m.fallbacks[reason] = counter
	}
	m.mu.Unlock()
	counter.Add(1)
}

func sanitizeOrderedRootProbeReason(reason string) string {
	if reason == "" {
		return "probe_error"
	}
	var b strings.Builder
	for _, r := range strings.ToLower(reason) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '_' || r == '-' {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	return b.String()
}

func expvarInt(name string) *expvar.Int {
	if existing := expvar.Get(name); existing != nil {
		if value, ok := existing.(*expvar.Int); ok {
			return value
		}
	}
	return expvar.NewInt(name)
}
