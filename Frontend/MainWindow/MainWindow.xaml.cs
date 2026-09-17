using System;
using System.Threading.Tasks;
using System.IO;
using System.Linq;
using System.Text.Json;
using Microsoft.Win32;
using System.Windows;
using SQLAuditor.Lib;

namespace SQLAuditor.Wpf
{
    public partial class MainWindow : Window
    {
        private sealed class SummaryMetricItem
        {
            public string Label { get; init; } = string.Empty;
            public int Value { get; init; }
            public int Total { get; init; }
            public string Detail { get; init; } = string.Empty;
            public System.Windows.Media.Brush BarBrush { get; init; } = System.Windows.Media.Brushes.SteelBlue;

            public double Percent => Total <= 0 ? 0.0 : (double)Value * 100.0 / Total;
            public string DisplayValue => Total <= 0 ? Value.ToString() : $"{Value} ({Percent:F0}%)";
        }

        private sealed class SummaryResultRow
        {
            public string Id { get; init; } = string.Empty;
            public string Description { get; init; } = string.Empty;
            public string Outcome { get; init; } = string.Empty;
            public string Technique { get; init; } = string.Empty;
        }

        private sealed class ManualEvaluationState
        {
            public string Instructions { get; set; } = string.Empty;
            public string Remarks { get; set; } = string.Empty;
            public string? SelectedOutcome { get; set; }
            public bool IsSubmitted { get; set; }

            // Set when the verdict came from attached evidence rather than from the reviewer. The
            // item stays in the queue so it can be inspected and overridden.
            public string? EvidenceSummary { get; set; }

            public bool IsEvidenceResolved => !string.IsNullOrWhiteSpace(EvidenceSummary);

            // The enriched result for the submitted outcome+remarks, so re-persisting after
            // the engine's placeholder write never repeats the LLM call.
            public SQLAuditor.Lib.ChecklistResult? EnrichedResult { get; set; }
            public string? EnrichedKey { get; set; }
        }

        private System.Threading.CancellationTokenSource? _progressWatcherCts;
        private long _progressStreamPos = 0;
        private bool _isVerified = false;
        private bool _isLlmVerified = false;
        private Auditor? _auditor;
        private System.Threading.CancellationTokenSource? _evaluationCts;
        private bool _isEvaluating = false;
        private bool _allowTabChange = false;
        private System.Threading.Tasks.TaskCompletionSource<string?>? _pendingUserInput;
        private System.Collections.Generic.List<SQLAuditor.Lib.ChecklistItem>? _loadedItems;
        private bool _checklistLoaded = false;
        // guards two-way sync between the "Select All" checkbox and the individual checklist checkboxes
        private bool _suppressSelectAllSync = false;
        // keep area association for items so UI can render Area -> Category -> Item
        private System.Collections.Generic.List<(string Area, SQLAuditor.Lib.ChecklistItem Item)>? _loadedStructure;
        private System.Collections.Generic.Dictionary<string, string>? _itemTypeMap;
        private System.Collections.Generic.Dictionary<string, string[]>? _itemScriptMap;
        private System.Collections.Generic.HashSet<string> _mcpFeasibleItemIds = new(StringComparer.OrdinalIgnoreCase);
        private System.Collections.Generic.List<SQLAuditor.Lib.ChecklistItem>? _manualQueue;
        private int _manualIndex = -1;
        // Checklist position per item id, so manual items generated in parallel stay in order.
        private System.Collections.Generic.Dictionary<string, int>? _checklistOrder;
        private System.Collections.Generic.Dictionary<string, string>? _manualInstructions;
        private System.Collections.Generic.Dictionary<string, ManualEvaluationState>? _manualStateMap;
        private System.Collections.Generic.Dictionary<string, (string Area, SQLAuditor.Lib.ChecklistItem Item)>? _evalItemMap;
        private System.Collections.Generic.Dictionary<string, (string Status, string Technique)>? _evalStatusMap;
        private bool _isHydratingManualUi = false;
        // Coalesces EvalTree rebuilds: a full re-render per progress event blocks the dispatcher
        // (and therefore the in-flight SQL/LLM continuations) once hundreds of items are loaded.
        private bool _treeRenderQueued = false;
        // Manual results are read-modify-written into one JSON file, so only one submission
        // may enrich and persist at a time.
        private readonly System.Threading.SemaphoreSlim _manualPersistLock = new(1, 1);
        // Selected checklist IDs are kept in-memory for the current session only
        private System.Collections.Generic.List<string>? _selectedIds;
        // Checklist IDs that already have a reusable manual result in results/historical_last_run.json
        private System.Collections.Generic.HashSet<string> _historicalManualIds = new(StringComparer.OrdinalIgnoreCase);
        // Manual IDs the current run copied from those historical results: they arrive decided, so
        // they have no ManualEvaluationState and must not be treated as an unfinished review.
        private System.Collections.Generic.HashSet<string> _copiedManualIds = new(StringComparer.OrdinalIgnoreCase);
        // guards the mapping-preview rebuild triggered by the Copy Manual Results checkbox
        private bool _suppressCopyManualReload = false;
        private readonly System.Collections.Generic.List<System.Windows.Controls.CheckBox> _databaseOptionCheckBoxes = new();
        private System.Windows.Controls.CheckBox? _allDatabasesCheckBox;
        private bool _suppressDatabaseSelectionSync = false;
        // Evidence artefacts the user attached: folders/files chosen here, and the indexed context.
        private readonly System.Collections.Generic.List<string> _evidenceFolders = new();
        private readonly System.Collections.Generic.List<string> _evidenceFiles = new();
        private SQLAuditor.Lib.EvidenceContext? _evidenceContext;
        private int _sqlConnectionInputsVersion = 0;
        private bool _isVerifyingSql = false;
        // True while the Summary page is showing a reused run rather than one evaluated in this session.
        private bool _viewingPreviousEvaluation = false;
        // Set when rerunning or editing a run from the Evaluations History window: reports are
        // regenerated into this existing run directory instead of a fresh one.
        private string? _resumeRunDirectory;
        private bool _resumeIsEdit;
        private string? _resumeFqdn;
        private System.Collections.Generic.List<string>? _resumeDatabases;
        private System.Collections.Generic.List<string>? _resumeSelectedItemIds;

        // Servers queued for a fleet audit. One entry behaves exactly like the old single-server flow.
        private readonly System.Collections.ObjectModel.ObservableCollection<ServerEntry> _servers = new();
        private bool _suppressMultiServerToggle;
        // Per-server copies of the evaluation/manual state, keyed by ServerEntry.DisplayName.
        private readonly System.Collections.Generic.Dictionary<string, ServerUiState> _serverUiStates =
            new(StringComparer.OrdinalIgnoreCase);
        private string? _selectedServerKey;
        // Set during a fleet run so file writes target the selected server, not the process-wide run.
        private string? _uiRunDirectory;
        private string? _batchDirectory;

        private sealed class ServerUiState
        {
            public required string DisplayName { get; init; }
            public string? RunDirectory { get; set; }
            public System.Collections.Generic.Dictionary<string, (string Area, SQLAuditor.Lib.ChecklistItem Item)> EvalItemMap { get; set; } = new();
            public System.Collections.Generic.Dictionary<string, (string Status, string Technique)> EvalStatusMap { get; set; } = new();
            public System.Collections.Generic.List<SQLAuditor.Lib.ChecklistItem> ManualQueue { get; set; } = new();
            public System.Collections.Generic.Dictionary<string, string> ManualInstructions { get; set; } = new();
            public System.Collections.Generic.Dictionary<string, ManualEvaluationState> ManualStateMap { get; set; } = new();
            public System.Collections.Generic.HashSet<string> CopiedManualIds { get; set; } = new(StringComparer.OrdinalIgnoreCase);
            public int ManualIndex { get; set; } = -1;
        }

        private string UiRunDirectory => _uiRunDirectory ?? AuditOutputPaths.CurrentRunDirectory;

        private string UiFilePath(string fileName) => System.IO.Path.Combine(UiRunDirectory, fileName);

        public MainWindow()
        {
            InitializeComponent();
            ServerListBox.ItemsSource = _servers;
            ServerProgressList.ItemsSource = _servers;
            _servers.CollectionChanged += (s, e) => UpdateServerListSummary();
            UpdateServerListSummary();
            // wire auth selection UI
            foreach (var method in SqlAuthProfile.AllMethods)
            {
                AuthMethodCombo.Items.Add(new System.Windows.Controls.ComboBoxItem
                {
                    Content = SqlAuthProfile.DisplayNameFor(method),
                    Tag = method,
                });
            }
            AuthMethodCombo.SelectedIndex = 0;
            AuthMethodCombo.SelectionChanged += (s, e) =>
            {
                ApplyAuthMode();
                InvalidateSqlVerification();
            };
            ApplyAuthMode();
            FqdnText.TextChanged += (s, e) => InvalidateSqlVerification();
            SqlUserBox.TextChanged += (s, e) => InvalidateSqlVerification();
            SqlPassBox.PasswordChanged += (s, e) => InvalidateSqlVerification();
            TenantIdBox.TextChanged += (s, e) => InvalidateSqlVerification();
            EncryptCheck.Checked += (s, e) => InvalidateSqlVerification();
            EncryptCheck.Unchecked += (s, e) => InvalidateSqlVerification();
            TrustServerCertCheck.Checked += (s, e) => InvalidateSqlVerification();
            TrustServerCertCheck.Unchecked += (s, e) => InvalidateSqlVerification();
            Log("Ready — enter SQL FQDN and click Verify Access.");
            // Start UI on Login tab (main window). Navigation via tab headers is disabled; use buttons to progress.
            MainTabs.SelectedIndex = 0;
            RefreshHistoricalManualAvailability();
            RefreshCustomChecklistCard();
            LoadChecklistBtn.IsEnabled = true;
            Log("Opened on Login view.");
            UpdateStageIndicators();
            // Do not auto-populate checklist on startup; user must click Load Checklist.
            // Do not start progress watcher until user triggers generation from Checklist tab.
            // Note: Load checklist only when user clicks the button. Do not auto-invoke on startup.
        }

        private async Task StartProgressWatcherAsync(System.Threading.CancellationToken token)
        {
            try
            {
                // Check agent availability and warn user if unreachable
                try
                {
                    if (_auditor != null)
                    {
                        var avail = await _auditor.IsAgentAvailableAsync();
                        if (!avail)
                        {
                            var mb = MessageBox.Show(this, "Configured SLM/LLM appears unreachable. Continue generation using local/fallback generator?\n\nChoose 'Yes' to continue (will use fallback and may produce placeholders), 'No' to cancel.", "Agent Unavailable", MessageBoxButton.YesNo, MessageBoxImage.Warning);
                                if (mb == MessageBoxResult.No)
                                {
                                    Log("Generation cancelled by user due to agent unavailability.");
                                    return;
                                }
                            else
                            {
                                Log("Continuing generation using fallback/local agent.");
                            }
                        }
                    }
                }
                catch (Exception exAvail)
                {
                    Log("Agent health check failed: " + exAvail.Message);
                }
                string? watchedPath = null;
                while (true)
                {
                    if (token.IsCancellationRequested) return;
                    try
                    {
                        var activeRunDirectory = AuditOutputPaths.ActiveRunDirectory;
                        if (activeRunDirectory == null)
                        {
                            try { await Task.Delay(1000, token); } catch (TaskCanceledException) { return; }
                            continue;
                        }

                        var path = System.IO.Path.Combine(activeRunDirectory, "progress_stream.txt");
                        if (!string.Equals(path, watchedPath, StringComparison.OrdinalIgnoreCase))
                        {
                            watchedPath = path;
                            _progressStreamPos = 0;
                        }

                        if (System.IO.File.Exists(path))
                        {
                            using (var fs = new System.IO.FileStream(path, System.IO.FileMode.Open, System.IO.FileAccess.Read, System.IO.FileShare.ReadWrite))
                            using (var sr = new System.IO.StreamReader(fs))
                            {
                                fs.Seek(_progressStreamPos, System.IO.SeekOrigin.Begin);
                                string? line;
                                while ((line = await sr.ReadLineAsync()) != null)
                                {
                                    // append to UI
                                    // write streamed progress lines to ui_log
                                    Log(line);
                                }
                                _progressStreamPos = fs.Position;
                            }
                        }
                    }
                    catch { }
                    try { await Task.Delay(1000, token); } catch (TaskCanceledException) { return; }
                }
            }
            catch { }
        }

        // The first run has no results/historical_last_run.json, so there is nothing to copy and
        // the checkbox stays disabled (and unchecked).
        private void RefreshHistoricalManualAvailability()
        {
            try
            {
                _historicalManualIds = SQLAuditor.Lib.HistoricalManualResultsStore.AvailableIds();
            }
            catch
            {
                _historicalManualIds = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
            }

            if (CopyManualResultsCb == null) return;

            var available = _historicalManualIds.Count > 0;
            CopyManualResultsCb.IsEnabled = available;
            if (!available && CopyManualResultsCb.IsChecked == true)
            {
                _suppressCopyManualReload = true;
                try { CopyManualResultsCb.IsChecked = false; }
                finally { _suppressCopyManualReload = false; }
            }
        }

        private bool UseHistoricalManualResults =>
            CopyManualResultsCb?.IsChecked == true && _historicalManualIds.Count > 0;

        private void CopyManualResultsCb_Changed(object sender, RoutedEventArgs e)
        {
            if (_suppressCopyManualReload) return;
            Log(UseHistoricalManualResults
                ? $"Copy Manual Results enabled — {_historicalManualIds.Count} manual result(s) available from last runs."
                : "Copy Manual Results disabled — every manual item will be evaluated normally.");
            // Mapping Preview classifies items by how they will be evaluated, so it is rebuilt.
            if (_checklistLoaded) LoadChecklistBtn_Click(sender, e);
        }

        private async void LoadChecklistBtn_Click(object sender, RoutedEventArgs e)
        {
            if (_auditor == null)
            {
                // Allow loading checklist without a verified DB connection for UI/testing convenience
                _auditor = new Auditor("");
                Log("No DB connection provided — using offline auditor for checklist load.");
            }
            RefreshHistoricalManualAvailability();
            Log("Loading checklist structure...");
            try
            {
                // Do not auto-generate placeholder scripts during checklist load; mapping should be authoritative.

                // Ensure checklist is loaded
                System.Collections.Generic.Dictionary<string, string[]?> mappingFile = new System.Collections.Generic.Dictionary<string, string[]?>();
                // Mirrors Auditor.CanTryMcp: a script-less admin or documentation check can never be
                // decided by MCP, so it must not be offered as AI-MCP here either.
                var operatorEvaluatedIds = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
                _mcpFeasibleItemIds = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
                // Mapped script paths are stored relative to the repo root, so the root that provided
                // the mapping is what resolves them (the process working directory is not the root).
                string? mappingRoot = null;
                try
                {
                    var dir = new DirectoryInfo(Directory.GetCurrentDirectory());
                    while (dir != null)
                    {
                        var candidate = Path.Combine(dir.FullName, "Backend", "checklists", "deterministic-script-mapping.json");
                        if (File.Exists(candidate))
                        {
                            mappingRoot = dir.FullName;
                            using var mapDoc = System.Text.Json.JsonDocument.Parse(File.ReadAllText(candidate));
                            foreach (var prop in mapDoc.RootElement.EnumerateObject())
                            {
                                if (prop.Value.ValueKind == System.Text.Json.JsonValueKind.Array)
                                {
                                    var arr = new System.Collections.Generic.List<string>();
                                    foreach (var el in prop.Value.EnumerateArray())
                                    {
                                        var s = el.GetString();
                                        if (!string.IsNullOrWhiteSpace(s)) arr.Add(s);
                                    }
                                    mappingFile[prop.Name] = arr.ToArray();
                                }
                                else if (prop.Value.ValueKind == System.Text.Json.JsonValueKind.Object)
                                {
                                    if (prop.Value.TryGetProperty("script_file", out var sf))
                                    {
                                        if (sf.ValueKind == System.Text.Json.JsonValueKind.String)
                                        {
                                            var s = sf.GetString();
                                            mappingFile[prop.Name] = string.IsNullOrWhiteSpace(s) ? null : new[] { s };
                                        }
                                        else
                                        {
                                            // script_file is null (non-feasible item)
                                            mappingFile[prop.Name] = null;
                                        }
                                    }

                                    var isOperatorEvaluated =
                                        (prop.Value.TryGetProperty("IsAdminCheck", out var adminCheck)
                                            && adminCheck.ValueKind == System.Text.Json.JsonValueKind.True)
                                        || (prop.Value.TryGetProperty("IsDocumentationCheck", out var docCheck)
                                            && docCheck.ValueKind == System.Text.Json.JsonValueKind.True);
                                    if (isOperatorEvaluated) operatorEvaluatedIds.Add(prop.Name);

                                    if (!isOperatorEvaluated
                                        && (!prop.Value.TryGetProperty("script_file", out var mappedScript)
                                            || mappedScript.ValueKind == System.Text.Json.JsonValueKind.Null
                                            || (mappedScript.ValueKind == System.Text.Json.JsonValueKind.String && string.IsNullOrWhiteSpace(mappedScript.GetString())))
                                        && prop.Value.TryGetProperty("MCP_Feasibility", out var mcpCheck)
                                        && mcpCheck.ValueKind == System.Text.Json.JsonValueKind.True)
                                    {
                                        _mcpFeasibleItemIds.Add(prop.Name);
                                    }
                                }
                            }
                            break;
                        }
                        dir = dir.Parent;
                    }
                }
                catch (Exception ex)
                {
                    Log("Failed to read deterministic-script-mapping.json: " + ex.Message);
                }

                if (mappingRoot == null)
                {
                    Log("deterministic-script-mapping.json not found — every item will preview as AI-Manual/AI-MCP.");
                }

                // prepare maps
                _itemTypeMap = new System.Collections.Generic.Dictionary<string, string>();
                _itemScriptMap = new System.Collections.Generic.Dictionary<string, string[]>();

                // pre-fill Script entries from mapping file, but validate mapped files exist and are not autogenerated placeholders
                if (_loadedItems != null)
                {
                    foreach (var it in _loadedItems)
                    {
                        if (mappingFile.TryGetValue(it.Id, out var files) && files != null && files.Length > 0)
                        {
                            var valid = new System.Collections.Generic.List<string>();
                            foreach (var f in files.Where(s => !string.IsNullOrWhiteSpace(s)))
                            {
                                try
                                {
                                    var candidate = f;
                                    if (!Path.IsPathRooted(candidate)) candidate = Path.Combine(mappingRoot ?? Directory.GetCurrentDirectory(), candidate.Replace('/', Path.DirectorySeparatorChar));
                                    if (!File.Exists(candidate)) continue;
                                    // ignore auto-generated placeholders
                                    var txt = File.ReadAllText(candidate);
                                    if (txt.IndexOf("Placeholder script for", StringComparison.OrdinalIgnoreCase) >= 0) continue;
                                    // keep the relative form if original was relative
                                    valid.Add(f);
                                }
                                catch { }
                            }
                            if (valid.Count > 0)
                            {
                                // A mapped script wins: mirrors Auditor.IsScriptMapped.
                                _itemTypeMap[it.Id] = "Script";
                                _itemScriptMap[it.Id] = valid.ToArray();
                            }
                        }
                    }
                }

                // Determine selected items from the already-populated ChecklistTree (Checklist should not change on Load)
                var selectedItems = new System.Collections.Generic.List<SQLAuditor.Lib.ChecklistItem>();
                foreach (var areaObj in ChecklistTree.Items)
                {
                    if (areaObj is System.Windows.Controls.TreeViewItem areaNode)
                    {
                        foreach (var catObj in areaNode.Items)
                        {
                            if (catObj is System.Windows.Controls.TreeViewItem catNode)
                            {
                                foreach (var itemObj in catNode.Items)
                                {
                                    if (itemObj is System.Windows.Controls.TreeViewItem itemTvi && itemTvi.Header is System.Windows.Controls.CheckBox cb)
                                    {
                                        if (cb.IsChecked == true && cb.Tag is SQLAuditor.Lib.ChecklistItem it)
                                        {
                                            selectedItems.Add(it);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if (selectedItems.Count == 0)
                {
                    Log("No items selected — Mapping Preview will show all items by category.");
                    // When no explicit selection, persist the full checklist as selected (so downstream actions evaluate all)
                }

                // Keep selected item IDs in-memory only (no disk persistence)
                try
                {
                    _selectedIds = (selectedItems.Count == 0 ? (_loadedItems ?? new System.Collections.Generic.List<SQLAuditor.Lib.ChecklistItem>()) : selectedItems).Select(i => i.Id).ToList();
                    Log($"Selected {_selectedIds.Count} checklist item(s) loaded into memory.");
                }
                catch (Exception ex)
                {
                    Log("Failed to populate selected checklist in-memory: " + ex.Message);
                }

                var mappingRows = new System.Collections.Generic.List<dynamic>();
                var copyManual = UseHistoricalManualResults;
                // Use in-memory selected IDs (if any) to determine which items to show/process
                var itemsToProcess = (_selectedIds != null && _selectedIds.Count > 0) ? (_loadedItems?.Where(i => _selectedIds.Contains(i.Id)).ToList() ?? new System.Collections.Generic.List<SQLAuditor.Lib.ChecklistItem>()) : (selectedItems.Count == 0 ? (_loadedItems ?? new System.Collections.Generic.List<SQLAuditor.Lib.ChecklistItem>()) : selectedItems);
                foreach (var it in itemsToProcess)
                {
                    string type;
                    string[] scripts = new string[0];
                    if (_itemTypeMap != null && _itemTypeMap.TryGetValue(it.Id, out var existing) && existing == "Script")
                    {
                        type = "Script";
                        if (_itemScriptMap != null && _itemScriptMap.TryGetValue(it.Id, out var s)) scripts = s;
                    }
                    else
                    {
                        type = _mcpFeasibleItemIds.Contains(it.Id) ? "AI-MCP" : "AI-Manual";

                        // persist into maps
                        if (_itemTypeMap != null) _itemTypeMap[it.Id] = type;
                        if (_itemScriptMap != null) _itemScriptMap[it.Id] = scripts;
                    }

                    // Only non-script items can be served from a previous run's manual results.
                    var copied = copyManual && type != "Script" && _historicalManualIds.Contains(it.Id);

                    var area = _loadedStructure?.FirstOrDefault(x => x.Item.Id == it.Id).Area ?? string.Empty;
                    mappingRows.Add(new { Type = type, Copied = copied, Area = area, Category = it.Category, Id = it.Id, Description = it.Description, Verification = it.Verification, ScriptFiles = string.Join(';', scripts) });
                }

                // Populate TreeView grouped by Area -> Category -> Item
                this.Dispatcher.Invoke(() =>
                {
                    int GetAreaKey(string name)
                    {
                        if (string.IsNullOrWhiteSpace(name)) return int.MaxValue;
                        var m = System.Text.RegularExpressions.Regex.Match(name, "\\d+");
                        if (m.Success && int.TryParse(m.Value, out var v)) return v;
                        return int.MaxValue;
                    }

                    // populate mapping tree hierarchically: DisplayType -> Area -> Category -> Item (with counts)
                    MappingTree.Items.Clear();
                    var normalized = mappingRows.Select(r => new { DisplayType = (bool)r.Copied ? "Copied from last runs" : (string)r.Type, Area = (string)r.Area, Category = (string)r.Category, Id = (string)r.Id, Description = (string)r.Description, ScriptFiles = (string)r.ScriptFiles });
                    var byType = normalized.GroupBy(r => r.DisplayType).OrderBy(t => t.Key);
                    foreach (var typeGrp in byType)
                    {
                        var typeName = typeGrp.Key;
                        int typeCount = typeGrp.Count();
                        var typeNode = new System.Windows.Controls.TreeViewItem() { Header = $"{typeName} ({typeCount} items)", IsExpanded = true };

                        var byArea = typeGrp.GroupBy(r => r.Area).OrderBy(a => GetAreaKey(a.Key));
                        foreach (var areaGrp2 in byArea)
                        {
                            var areaName = areaGrp2.Key;
                            var categories = areaGrp2.GroupBy(r => r.Category).OrderBy(c => c.Key).ToList();
                            int areaCategoriesCount = categories.Count;
                            int areaItemsCount = areaGrp2.Count();
                            var areaHeaderItem = new System.Windows.Controls.TreeViewItem() { Header = $"{areaName} ({areaCategoriesCount} categories, {areaItemsCount} items)", IsExpanded = true };
                            foreach (var catGrp2 in categories)
                            {
                                var catLabel = catGrp2.Key;
                                int catCount = catGrp2.Count();
                                var catNode2 = new System.Windows.Controls.TreeViewItem() { Header = $"{catLabel} ({catCount})", IsExpanded = true };
                                foreach (var row in catGrp2.OrderBy(r => r.Id))
                                {
                                    var scripts = row.ScriptFiles;
                                    var itemText = $"{row.Id} {row.Description}" + (string.IsNullOrWhiteSpace(scripts) ? string.Empty : $" — Scripts: {scripts}");
                                    var itemNode = new System.Windows.Controls.TreeViewItem() { Header = itemText };
                                    catNode2.Items.Add(itemNode);
                                }
                                areaHeaderItem.Items.Add(catNode2);
                            }
                            typeNode.Items.Add(areaHeaderItem);
                        }

                        MappingTree.Items.Add(typeNode);
                    }
                });
                // Note: do not auto-persist deterministic mapping here. Mapping is authoritative and should be managed intentionally.

                // mark that user has explicitly loaded the checklist so UI actions become available
                _checklistLoaded = true;
                StartEvalBtn.IsEnabled = (_loadedItems != null && _loadedItems.Count > 0);
                Log("Checklist loaded.");
            }
            catch (Exception ex)
            {
                Log("Error loading checklist: " + ex.Message);
            }
        }

        private async void LoadScriptsBtn_Click(object sender, RoutedEventArgs e)
        {
            // Deprecated: functionality merged into Load Checklist
            Log("Load Scripts button is deprecated; use Load Checklist instead.");
        }

        private void UpdateServerListSummary()
        {
            ServerListCountText.Text = _servers.Count switch
            {
                0 => "none added",
                1 => "1 server",
                _ => $"{_servers.Count} servers"
            };

            var hasServers = _servers.Count > 0;
            ServerListBox.Visibility = hasServers ? Visibility.Visible : Visibility.Collapsed;
            ServerEmptyState.Visibility = hasServers ? Visibility.Collapsed : Visibility.Visible;
        }

        private void AddServerBtn_Click(object sender, RoutedEventArgs e)
        {
            var fqdn = FqdnText.Text?.Trim() ?? string.Empty;
            if (string.IsNullOrEmpty(fqdn))
            {
                MessageBox.Show(this, "Enter a SQL Server FQDN before adding it to the list.", "Server Required", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            // The same instance may be added more than once; each copy needs its own label so
            // progress and run folders stay distinguishable.
            var label = fqdn;
            var copy = 2;
            while (_servers.Any(s => string.Equals(s.DisplayName, label, StringComparison.OrdinalIgnoreCase)))
            {
                label = $"{fqdn} #{copy++}";
            }

            var isSqlLogin = string.Equals(
                (AuthMethodCombo.SelectedItem as System.Windows.Controls.ComboBoxItem)?.Content?.ToString(),
                "SQL Login", StringComparison.OrdinalIgnoreCase);

            if (isSqlLogin && (string.IsNullOrWhiteSpace(SqlUserBox.Text) || string.IsNullOrEmpty(SqlPassBox.Password)))
            {
                MessageBox.Show(this, "SQL Login needs both a username and a password.", "Credentials Required", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            var selectedDatabases = GetSelectedDatabaseNames();
            var entry = new ServerEntry
            {
                Server = fqdn,
                Name = label,
                AuthMode = isSqlLogin ? ServerAuthMode.Sql : ServerAuthMode.Windows,
                User = isSqlLogin ? SqlUserBox.Text.Trim() : null,
                Password = isSqlLogin ? SqlPassBox.Password : null,
                Databases = selectedDatabases.Length > 0 ? selectedDatabases : null,
                Status = _isVerified ? "Verified" : "Not verified",
            };

            _servers.Add(entry);
            Log($"Added {label} to the server list ({entry.AuthLabel}).");
        }

        private void RemoveServerRow_Click(object sender, RoutedEventArgs e)
        {
            if ((sender as System.Windows.Controls.Button)?.Tag is not ServerEntry entry) return;

            _servers.Remove(entry);
            Log($"Removed {entry.DisplayName} from the server list.");
        }

        /// <summary>
        /// Multi-server mode is opt-in: the evaluation dispatch keys off _servers.Count, so leaving
        /// the mode clears the list to keep a single-server run on the single-server path.
        /// </summary>
        private void MultiServerToggle_Changed(object sender, RoutedEventArgs e)
        {
            if (_suppressMultiServerToggle) return;

            var multiServer = MultiServerToggle.IsChecked == true;

            if (!multiServer && _servers.Count > 0)
            {
                var confirm = MessageBox.Show(
                    this,
                    $"Switching back to a single-server audit removes the {_servers.Count} server(s) you added. Continue?",
                    "Clear Server List",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Question);

                if (confirm != MessageBoxResult.Yes)
                {
                    _suppressMultiServerToggle = true;
                    MultiServerToggle.IsChecked = true;
                    _suppressMultiServerToggle = false;
                    return;
                }

                _servers.Clear();
            }

            ServerListSection.Visibility = multiServer ? Visibility.Visible : Visibility.Collapsed;
            ServersRow.Height = multiServer ? new GridLength(1, GridUnitType.Star) : GridLength.Auto;

            Log(multiServer
                ? "Multi-server mode on — add the servers to run in parallel."
                : "Multi-server mode off — only the verified server will be audited.");
        }

        /// <summary>
        /// Once the server list is scrolled to its limit, hand the wheel back to the page so the
        /// tab keeps scrolling instead of stalling under the cursor.
        /// </summary>
        private void ServerListBox_PreviewMouseWheel(object sender, System.Windows.Input.MouseWheelEventArgs e)
        {
            var scroll = FindDescendant<System.Windows.Controls.ScrollViewer>(ServerListBox);
            if (scroll == null) return;

            var atTop = e.Delta > 0 && scroll.VerticalOffset <= 0;
            var atBottom = e.Delta < 0 && scroll.VerticalOffset >= scroll.ScrollableHeight;
            if (!atTop && !atBottom) return;

            e.Handled = true;
            ServerListBox.RaiseEvent(new System.Windows.Input.MouseWheelEventArgs(e.MouseDevice, e.Timestamp, e.Delta)
            {
                RoutedEvent = UIElement.MouseWheelEvent,
                Source = ServerListBox,
            });
        }

        private static T? FindDescendant<T>(DependencyObject root) where T : DependencyObject
        {
            var count = System.Windows.Media.VisualTreeHelper.GetChildrenCount(root);
            for (var i = 0; i < count; i++)
            {
                var child = System.Windows.Media.VisualTreeHelper.GetChild(root, i);
                if (child is T match) return match;

                var nested = FindDescendant<T>(child);
                if (nested != null) return nested;
            }

            return null;
        }

        private void ImportServersBtn_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new OpenFileDialog
            {
                Title = "Import server list",
                Filter = "Server list (*.json;*.csv)|*.json;*.csv|All files (*.*)|*.*",
            };
            if (dialog.ShowDialog(this) != true) return;

            var loaded = ServerTargetLoader.FromFile(dialog.FileName);
            foreach (var error in loaded.Errors) Log($"Server list: {error}");

            var added = 0;
            foreach (var target in loaded.Targets)
            {
                if (_servers.Any(s => string.Equals(s.DisplayName, target.DisplayName, StringComparison.OrdinalIgnoreCase))) continue;
                _servers.Add(new ServerEntry
                {
                    Server = target.Server,
                    Name = target.DisplayName,
                    AuthMode = target.AuthMode,
                    User = target.User,
                    Password = target.Password,
                    Databases = target.Databases,
                });
                added++;
            }

            Log($"Imported {added} server(s) from {System.IO.Path.GetFileName(dialog.FileName)}.");
            if (added == 0 && loaded.Errors.Count > 0)
            {
                MessageBox.Show(this, string.Join(Environment.NewLine, loaded.Errors), "Import Failed", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        /// <summary>
        /// Fleet path: every server runs the same item selection concurrently, each in its own run
        /// folder and with its own copy of the evaluation/manual UI state. The Servers list selects
        /// which server the tree and the manual panel are showing.
        /// </summary>
        private async Task RunMultiServerEvaluationAsync(System.Collections.Generic.List<string> selected)
        {
            var maxParallel = MultiServerRunOptions.DefaultMaxParallel;

            SetTabIndex(2);
            UpdateStageIndicators();
            EvalTree.Items.Clear();
            ServerProgressPanel.Visibility = Visibility.Visible;
            _batchDirectory = MultiServerRunner.CreateBatchDirectory();

            _checklistOrder = new System.Collections.Generic.Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            if (_loadedStructure != null)
            {
                var checklistPosition = 0;
                foreach (var pair in _loadedStructure) _checklistOrder[pair.Item.Id] = checklistPosition++;
            }

            _serverUiStates.Clear();
            _selectedServerKey = null;
            foreach (var entry in _servers)
            {
                var state = new ServerUiState { DisplayName = entry.DisplayName };
                PopulateServerUiState(state, selected);
                _serverUiStates[entry.DisplayName] = state;
                entry.Status = "Queued";
            }

            // Progress objects must be built here so each one captures the UI SynchronizationContext;
            // the runner invokes the factory from a worker thread.
            var progressByServer = new System.Collections.Generic.Dictionary<string, IProgress<SQLAuditor.Lib.ChecklistResult>>(StringComparer.OrdinalIgnoreCase);
            foreach (var entry in _servers)
            {
                var key = entry.DisplayName;
                progressByServer[key] = new Progress<SQLAuditor.Lib.ChecklistResult>(r => ApplyServerItemProgress(key, r));
            }

            SelectServer(_servers[0].DisplayName);
            Log($"Starting fleet evaluation of {_servers.Count} server(s), {maxParallel} at a time.");

            var serverProgress = new Progress<ServerRunResult>(r =>
            {
                var entry = _servers.FirstOrDefault(s => string.Equals(s.DisplayName, r.DisplayName, StringComparison.OrdinalIgnoreCase));
                if (entry != null)
                {
                    entry.Status = r.Status switch
                    {
                        ServerRunStatus.Running => "Running...",
                        ServerRunStatus.Succeeded => $"Done ({r.ItemsEvaluated})",
                        ServerRunStatus.Canceled => "Canceled",
                        _ => "Failed"
                    };
                    entry.RunDirectory = r.RunDirectory;
                }

                if (_serverUiStates.TryGetValue(r.DisplayName, out var state))
                {
                    state.RunDirectory = r.RunDirectory;
                    if (string.Equals(_selectedServerKey, r.DisplayName, StringComparison.OrdinalIgnoreCase))
                    {
                        _uiRunDirectory = r.RunDirectory;
                    }
                }

                if (r.Status == ServerRunStatus.Running) return;

                RequestEvaluationTreeRender();
                Log(r.Status == ServerRunStatus.Succeeded
                    ? $"[{r.DisplayName}] {r.ItemsEvaluated} item(s) evaluated -> {r.RunDirectory}"
                    : $"[{r.DisplayName}] {r.Status}: {r.Error}");
            });

            try
            {
                _evaluationCts = new System.Threading.CancellationTokenSource();
                _isEvaluating = true;

                var targetsByKey = _servers.ToDictionary(s => s.DisplayName, s => s.ToTarget(), StringComparer.OrdinalIgnoreCase);
                var options = new MultiServerRunOptions
                {
                    Targets = targetsByKey.Values.ToList(),
                    SelectedIds = selected,
                    UseHistoricalManualResults = UseHistoricalManualResults,
                    MaxParallel = maxParallel,
                    BatchDirectory = _batchDirectory,
                    ProgressFactory = target => progressByServer.TryGetValue(target.DisplayName, out var p) ? p : null,
                    UserInputFactory = target =>
                    {
                        var key = target.DisplayName;
                        return (item, instructions) => QueueServerManualItemAsync(key, item, instructions);
                    },
                };

                var batch = await Task.Run(
                    () => MultiServerRunner.RunAsync(options, serverProgress, _evaluationCts.Token),
                    _evaluationCts.Token);

                _isEvaluating = false;

                // Manual decisions submitted while the run was in flight are written per server.
                // Reports are regenerated once afterwards; RegenerateReportFromPersisted already
                // covers every server in a fleet run.
                foreach (var entry in _servers)
                {
                    if (!_serverUiStates.TryGetValue(entry.DisplayName, out var state) || state.RunDirectory is null) continue;
                    SelectServer(entry.DisplayName);
                    await ReapplySubmittedManualResultsAsync();
                }

                SelectServer(_servers[0].DisplayName);
                RegenerateReportFromPersisted();
                UpdateSummaryView(LoadPersistedResults() ?? Array.Empty<ChecklistResult>());

                var pendingManual = _serverUiStates.Values.Sum(s => s.ManualQueue.Count(i =>
                    !s.ManualStateMap.TryGetValue(i.Id, out var st) || !st.IsSubmitted));

                Log($"Fleet evaluation complete. {batch.SucceededCount} succeeded, {batch.FailedCount} failed, {batch.CanceledCount} canceled.");
                Log($"Batch manifest: {System.IO.Path.Combine(batch.BatchDirectory, MultiServerRunner.ManifestFileName)}");
                MessageBox.Show(
                    this,
                    $"Fleet evaluation finished.\n\n{batch.SucceededCount} succeeded, {batch.FailedCount} failed, {batch.CanceledCount} canceled."
                    + (pendingManual > 0
                        ? $"\n\n{pendingManual} manual item(s) still need a decision. Pick a server in the Servers list to review its items."
                        : string.Empty),
                    "Fleet Evaluation Complete",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
            }
            catch (OperationCanceledException)
            {
                Log("Fleet evaluation cancelled.");
            }
            catch (Exception ex)
            {
                Log("Fleet evaluation error: " + ex.Message);
            }
            finally
            {
                _isEvaluating = false;
            }
        }

        // Mirrors the single-server initialisation so each server starts with the same
        // "Not Started" tree and the same historical-reuse decisions.
        private void PopulateServerUiState(ServerUiState state, System.Collections.Generic.List<string> selected)
        {
            var selectedLookup = new System.Collections.Generic.HashSet<string>(selected, StringComparer.OrdinalIgnoreCase);

            if (UseHistoricalManualResults)
            {
                foreach (var id in selected)
                {
                    if (!_historicalManualIds.Contains(id)) continue;
                    if (_itemTypeMap != null && _itemTypeMap.TryGetValue(id, out var t)
                        && string.Equals(t, "Script", StringComparison.OrdinalIgnoreCase)) continue;
                    state.CopiedManualIds.Add(id);
                }
            }

            if (_loadedStructure == null) return;

            foreach (var pair in _loadedStructure)
            {
                if (!selectedLookup.Contains(pair.Item.Id)) continue;
                state.EvalItemMap[pair.Item.Id] = pair;

                var initialTechnique = "AI-Manual";
                if (_itemTypeMap != null && _itemTypeMap.TryGetValue(pair.Item.Id, out var mappedType)
                    && string.Equals(mappedType, "Script", StringComparison.OrdinalIgnoreCase))
                {
                    initialTechnique = "Script";
                }
                else if (_mcpFeasibleItemIds.Contains(pair.Item.Id))
                {
                    initialTechnique = "AI-MCP";
                }

                state.EvalStatusMap[pair.Item.Id] = ("Not Started", initialTechnique);
            }
        }

        private void ApplyServerItemProgress(string serverKey, SQLAuditor.Lib.ChecklistResult r)
        {
            if (!_serverUiStates.TryGetValue(serverKey, out var state)) return;
            if (!state.EvalItemMap.ContainsKey(r.Id)) return;

            var uiOutcome = NormalizeUiStatus(r.Outcome, r.Technique);
            var current = state.EvalStatusMap.TryGetValue(r.Id, out var st) ? st.Status : "Not Started";

            // Do not regress pending/submitted manual states back to generating/evaluating.
            var isIncomingIntermediate = string.Equals(uiOutcome, "Generating Manual Plan", StringComparison.OrdinalIgnoreCase)
                || string.Equals(uiOutcome, "Evaluating", StringComparison.OrdinalIgnoreCase);
            var isCurrentReady = string.Equals(current, "Pending Manual Evaluation", StringComparison.OrdinalIgnoreCase)
                || string.Equals(current, "Passed", StringComparison.OrdinalIgnoreCase)
                || string.Equals(current, "Failed", StringComparison.OrdinalIgnoreCase);

            if (!(isIncomingIntermediate && isCurrentReady))
            {
                state.EvalStatusMap[r.Id] = (uiOutcome, r.Technique);
            }

            // Every server is visible in the tree, so any server's progress repaints it.
            RequestEvaluationTreeRender();
            UpdateEvaluationProgressDisplay();
        }
        private Task<string?> QueueServerManualItemAsync(string serverKey, SQLAuditor.Lib.ChecklistItem item, string instructionsFromAuditor)
        {
            var instructions = instructionsFromAuditor ?? string.Empty;
            try
            {
                this.Dispatcher.Invoke(() =>
                {
                    if (!_serverUiStates.TryGetValue(serverKey, out var state)) return;

                    if (!state.ManualQueue.Any(q => string.Equals(q.Id, item.Id, StringComparison.OrdinalIgnoreCase)))
                    {
                        var position = _checklistOrder != null && _checklistOrder.TryGetValue(item.Id, out var order) ? order : int.MaxValue;
                        var index = state.ManualQueue.FindIndex(q =>
                            (_checklistOrder != null && _checklistOrder.TryGetValue(q.Id, out var o) ? o : int.MaxValue) > position);
                        if (index < 0) state.ManualQueue.Add(item);
                        else state.ManualQueue.Insert(index, item);
                    }

                    state.ManualInstructions[item.Id] = instructions;
                    if (!state.ManualStateMap.TryGetValue(item.Id, out var manualState))
                    {
                        manualState = new ManualEvaluationState();
                        state.ManualStateMap[item.Id] = manualState;
                    }
                    manualState.Instructions = instructions;

                    if (!manualState.IsSubmitted)
                    {
                        state.EvalStatusMap[item.Id] = ("Pending Manual Evaluation", "AI-Manual");
                    }
                    if (state.ManualIndex == -1) state.ManualIndex = 0;

                    if (string.Equals(_selectedServerKey, serverKey, StringComparison.OrdinalIgnoreCase))
                    {
                        if (_manualIndex == -1) _manualIndex = 0;
                        ShowManualAtIndex();
                    }

                    RequestEvaluationTreeRender();
                });
            }
            catch { }

            // Returns immediately: several servers evaluate at once, so this must never block.
            return Task.FromResult<string?>(string.Empty);
        }

        private void SelectServer(string key)
        {
            if (_selectedServerKey != null && _serverUiStates.TryGetValue(_selectedServerKey, out var previous))
            {
                previous.ManualIndex = _manualIndex;
            }

            if (!_serverUiStates.TryGetValue(key, out var next)) return;

            _selectedServerKey = key;
            _uiRunDirectory = next.RunDirectory;
            _evalItemMap = next.EvalItemMap;
            _evalStatusMap = next.EvalStatusMap;
            _manualQueue = next.ManualQueue;
            _manualInstructions = next.ManualInstructions;
            _manualStateMap = next.ManualStateMap;
            _copiedManualIds = next.CopiedManualIds;
            _manualIndex = next.ManualIndex;

            if (ServerProgressList != null)
            {
                var entry = _servers.FirstOrDefault(s => string.Equals(s.DisplayName, key, StringComparison.OrdinalIgnoreCase));
                if (!ReferenceEquals(ServerProgressList.SelectedItem, entry)) ServerProgressList.SelectedItem = entry;
            }

            RenderEvaluationTree();
            UpdateEvaluationProgressDisplay();
            ShowManualAtIndex();
        }

        private void ServerProgressList_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
        {
            if (ServerProgressList.SelectedItem is ServerEntry entry
                && !string.Equals(_selectedServerKey, entry.DisplayName, StringComparison.OrdinalIgnoreCase))
            {
                SelectServer(entry.DisplayName);
            }
        }

        private async void StartEvalBtn_Click(object sender, RoutedEventArgs e)
        {
            var selectedChecklistIds = _selectedIds is { Count: > 0 }
                ? new System.Collections.Generic.List<string>(_selectedIds)
                : new System.Collections.Generic.List<string>();

            if (_servers.Count > 1)
            {
                if (selectedChecklistIds.Count == 0)
                {
                    MessageBox.Show("No loaded checklist selection found. Click Load Checklist first.", "Selection Required", MessageBoxButton.OK, MessageBoxImage.Information);
                    return;
                }

                await RunMultiServerEvaluationAsync(selectedChecklistIds);
                return;
            }

            // A single-server run owns the process-wide run directory again.
            _batchDirectory = null;
            _uiRunDirectory = null;
            _selectedServerKey = null;
            _serverUiStates.Clear();
            ServerProgressPanel.Visibility = Visibility.Collapsed;

            var targetDatabases = GetSelectedDatabaseNames();
            if (targetDatabases.Length == 0)
            {
                MessageBox.Show("Select at least one database before evaluation.", "Database Selection Required", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            // Initialize auditor with declared FQDN for this evaluation run
            var fqdn = !string.IsNullOrWhiteSpace(FqdnText.Text) ? FqdnText.Text.Trim() : "abc.windows.net";
            await EnsureAuditor(fqdn);
            // Use selection captured during Load Checklist.
            var selected = new System.Collections.Generic.List<string>();
            try
            {
                if (_selectedIds != null && _selectedIds.Count > 0) selected.AddRange(_selectedIds);
            }
            catch { }
            if (selected.Count == 0)
            {
                MessageBox.Show("No loaded checklist selection found. Click Load Checklist first.", "Selection Required", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            // Rerun/edit from history: reuse the original run folder. Whether prior manual decisions
            // are reused is controlled by the existing "Copy Manual Results (Last Runs)" checkbox.
            var reuseFolder = false;
            if (_resumeRunDirectory != null)
            {
                try
                {
                    AuditOutputPaths.ResumeRun(_resumeRunDirectory);
                    reuseFolder = true;
                    RefreshHistoricalManualAvailability();
                    Log($"Rerun target: {System.IO.Path.GetFileName(_resumeRunDirectory)} (reports overwrite this folder).");
                }
                catch (Exception ex)
                {
                    Log("Could not reuse the previous run folder; a new one will be created: " + ex.Message);
                }
            }

            // move to evaluation page and build EvalTree
            SetTabIndex(2);
            UpdateStageIndicators();
            EvalTree.Items.Clear();
            UpdateStageIndicators();

            // Initialize evaluation state for selected items only.
            _manualQueue = new System.Collections.Generic.List<SQLAuditor.Lib.ChecklistItem>();
            _manualInstructions = new System.Collections.Generic.Dictionary<string, string>();
            _manualStateMap = new System.Collections.Generic.Dictionary<string, ManualEvaluationState>();
            _manualIndex = -1;
            _evalItemMap = new System.Collections.Generic.Dictionary<string, (string Area, SQLAuditor.Lib.ChecklistItem Item)>();
            _evalStatusMap = new System.Collections.Generic.Dictionary<string, (string Status, string Technique)>();
            _checklistOrder = new System.Collections.Generic.Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            if (_loadedStructure != null)
            {
                var checklistPosition = 0;
                foreach (var pair in _loadedStructure) _checklistOrder[pair.Item.Id] = checklistPosition++;
            }

            var selectedLookup = new System.Collections.Generic.HashSet<string>(selected);

            // Mirrors the engine's reuse predicate: a non-script item with a completed manual
            // result recorded by an earlier run is copied forward instead of being reviewed.
            _copiedManualIds = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (UseHistoricalManualResults)
            {
                foreach (var id in selected)
                {
                    if (!_historicalManualIds.Contains(id)) continue;
                    if (_itemTypeMap != null && _itemTypeMap.TryGetValue(id, out var t)
                        && string.Equals(t, "Script", StringComparison.OrdinalIgnoreCase)) continue;
                    _copiedManualIds.Add(id);
                }
            }

            if (_loadedStructure != null)
            {
                foreach (var pair in _loadedStructure)
                {
                    if (!selectedLookup.Contains(pair.Item.Id)) continue;
                    _evalItemMap[pair.Item.Id] = pair;

                    var initialTechnique = "AI-Manual";
                    if (_itemTypeMap != null && _itemTypeMap.TryGetValue(pair.Item.Id, out var mappedType) && string.Equals(mappedType, "Script", StringComparison.OrdinalIgnoreCase))
                    {
                        initialTechnique = "Script";
                    }
                    else if (_isVerified && _auditor != null && _mcpFeasibleItemIds.Contains(pair.Item.Id))
                    {
                        initialTechnique = "AI-MCP";
                    }

                    _evalStatusMap[pair.Item.Id] = ("Not Started", initialTechnique);
                }
            }

            RenderEvaluationTree();
            UpdateEvaluationProgressDisplay();
            ShowManualAtIndex();
            Log("Starting evaluation...");

            var progress = new Progress<SQLAuditor.Lib.ChecklistResult>(r =>
            {
                var uiOutcome = NormalizeUiStatus(r.Outcome, r.Technique);
                Log($"[{r.Id}] {uiOutcome} ({r.Technique})");

                try
                {
                    this.Dispatcher.Invoke(() =>
                    {
                        if (_evalStatusMap != null && _evalItemMap != null && _evalItemMap.ContainsKey(r.Id))
                        {
                            var current = _evalStatusMap.TryGetValue(r.Id, out var st) ? st.Status : "Not Started";

                            // Do not regress pending/submitted manual states back to generating/evaluating.
                            var isIncomingIntermediate = string.Equals(uiOutcome, "Generating Manual Plan", StringComparison.OrdinalIgnoreCase)
                                || string.Equals(uiOutcome, "Evaluating", StringComparison.OrdinalIgnoreCase);
                            var isCurrentReady = string.Equals(current, "Pending Manual Evaluation", StringComparison.OrdinalIgnoreCase)
                                || string.Equals(current, "Passed", StringComparison.OrdinalIgnoreCase)
                                || string.Equals(current, "Failed", StringComparison.OrdinalIgnoreCase);

                            if (!(isIncomingIntermediate && isCurrentReady))
                            {
                                _evalStatusMap[r.Id] = (uiOutcome, r.Technique);
                            }

                            RequestEvaluationTreeRender();
                            UpdateManualActionButtonStates(GetCurrentManualSelectedOutcome(), IsCurrentManualSubmitted());
                        }
                    });
                }
                catch { }
            });

            async Task<string?> RequestUserInput(SQLAuditor.Lib.ChecklistItem item, string instructionsFromAuditor)
            {
                // Queue manual validation without blocking evaluation flow.
                try
                {
                    var instructions = instructionsFromAuditor ?? string.Empty;
                    this.Dispatcher.Invoke(() =>
                    {
                        Log($"Manual input required for {item.Id}: {item.Description}");
                        // Ensure manual queue contains this item
                        if (_manualQueue == null) _manualQueue = new System.Collections.Generic.List<SQLAuditor.Lib.ChecklistItem>();
                        if (_manualInstructions == null) _manualInstructions = new System.Collections.Generic.Dictionary<string, string>();
                        if (_manualStateMap == null) _manualStateMap = new System.Collections.Generic.Dictionary<string, ManualEvaluationState>();
                        InsertManualQueueItem(item);
                        _manualInstructions[item.Id] = instructions ?? string.Empty;

                        var state = EnsureManualState(item.Id);
                        state.Instructions = instructions ?? string.Empty;
                        if (_manualIndex == -1) _manualIndex = 0;

                        if (_evalStatusMap != null)
                        {
                            if (!state.IsSubmitted)
                            {
                                _evalStatusMap[item.Id] = ("Pending Manual Evaluation", "AI-Manual");
                            }
                            RequestEvaluationTreeRender();
                        }
                        ShowManualAtIndex();
                    });
                }
                catch
                {
                    this.Dispatcher.Invoke(() => Log("Failed to generate manual instructions."));
                }

                // Return immediately so next checklist item starts without waiting for manual PASS/FAIL.
                await Task.CompletedTask;
                return string.Empty;
            }

            try
            {
                _evaluationCts = new System.Threading.CancellationTokenSource();
                _isEvaluating = true;
                var token = _evaluationCts.Token;
                var idsForRun = selected.Count == 0 ? null : selected;
                var useHistorical = UseHistoricalManualResults;
                _auditor!.LastRunInputs = BuildRunInputs();
                SQLAuditor.Lib.Auditor.ClearProviderFault();
                await EnsureEvidenceIndexedAsync();
                if (useHistorical)
                {
                    Log($"Reusing manual results from last runs for {_copiedManualIds.Count} selected item(s); manual review is skipped for them.");
                }
                // The engine must not run on the dispatcher. Awaiting it directly kept every SQL
                // and LLM continuation on the UI thread, so a manual Pass/Fail click (file I/O +
                // full tree rebuild) stalled the in-flight script pipeline; the aborted command
                // then left the shared connection broken and every remaining script item came
                // back as a SQL error, which the outcome mapper scores as Fail.
                var results = await Task.Run(
                    () => _auditor!.RunChecklistAsync(progress, RequestUserInput, idsForRun, token, useHistorical, generateReports: true, targetDatabases: targetDatabases, reuseActiveRunDirectory: reuseFolder, evidenceContext: _evidenceContext),
                    token);

                // Saved here because the evidence is indexed before this run's directory exists.
                if (_evidenceContext != null) SQLAuditor.Lib.EvidenceStore.Save(_evidenceContext);
                ReportProviderFault();
                // The engine's final write persists manual items as "Evaluating" placeholders,
                // which can overwrite Pass/Fail decisions made while evaluation was still running.
                // Re-apply submitted manual outcomes, then refresh the report/summary from the merged file.
                await ReapplySubmittedManualResultsAsync();
                RegenerateReportFromPersisted();
                RegisterEvidenceResolvedItems(results);
                UpdateEvaluationProgressDisplay();
                LogPlatformSummary();
                Log($"Evaluation complete. {results.Length} items evaluated. Results in results/ folder.");
                UpdateSummaryView(LoadPersistedResults() ?? results);
                MessageBox.Show(this, "Evaluation completed successfully.", "Evaluation Complete", MessageBoxButton.OK, MessageBoxImage.Information);
                // checklist_results.json and the full five-file report suite are produced
                // automatically by the Auditor at the end of the assessment.
                Log($"Summary report generated at {UiFilePath(SqlAuditor.Reporting.ReportSuiteGenerator.AuditReportFileName)}");
            }
            catch (OperationCanceledException)
            {
                Log("Evaluation cancelled. Existing result files were left unchanged.");
            }
            catch (Exception ex)
            {
                Log("Evaluation error: " + ex.Message);
            }
            finally
            {
                _isEvaluating = false;
            }
        }

        // Mirrors the banner the CLI and MCP hosts print, so a platform-excluded item is
        // visibly accounted for here instead of silently appearing as Not Applicable.
        private void LogPlatformSummary()
        {
            if (_auditor?.LastDetectedPlatform is not { } platform
                || platform.Platform == SQLAuditor.Lib.PlatformApplicability.PlatformUnknown)
                return;

            Log($"Detected platform: {platform.Display} (EngineEdition {platform.EngineEdition}).");
            if (_auditor.LastPlatformExclusionCount > 0)
                Log($"{_auditor.LastPlatformExclusionCount} item(s) recorded as Not Applicable to this platform - no script ran and no model was called for them.");
        }

        private async void RunAllBtn_Click(object sender, RoutedEventArgs e)
        {
            var fqdn = FqdnText.Text.Trim();
            if (string.IsNullOrEmpty(fqdn)) { Log("Enter FQDN first."); return; }
            Log($"Starting checklist evaluation on {fqdn}...");
            await EnsureAuditor(fqdn);
            try
            {
                var progress = new Progress<SQLAuditor.Lib.ChecklistResult>(r =>
                {
                    // update UI with progress
                    this.Dispatcher.Invoke(() =>
                    {
                        Log($"[{r.Id}] {r.Outcome} ({r.Technique})");
                    });
                });

                // requestUserInput delegate
                async Task<string?> RequestUserInput(SQLAuditor.Lib.ChecklistItem item, string instructionsFromAuditor)
                {
                    this.Dispatcher.Invoke(() =>
                    {
                        Log($"Manual input required for {item.Id}: {item.Description}");
                        if (!string.IsNullOrWhiteSpace(instructionsFromAuditor))
                        {
                            Log($"Manual steps: {instructionsFromAuditor}");
                        }
                        Log("Please type response in the input box and press Send (e.g. 'Yes' / 'No' / notes).");
                    });
                    _pendingUserInput = new System.Threading.Tasks.TaskCompletionSource<string?>();
                    // wait for user response (no timeout)
                    var resp = await _pendingUserInput.Task;
                    return resp;
                }

                _evaluationCts = new System.Threading.CancellationTokenSource();
                _isEvaluating = true;
                var targetDatabases = GetSelectedDatabaseNames();
                if (targetDatabases.Length == 0)
                {
                    MessageBox.Show("Select at least one database before evaluation.", "Database Selection Required", MessageBoxButton.OK, MessageBoxImage.Information);
                    return;
                }
                SQLAuditor.Lib.Auditor.ClearProviderFault();
                await EnsureEvidenceIndexedAsync();
                var results = await _auditor!.RunChecklistAsync(progress, RequestUserInput, null, _evaluationCts.Token, useHistoricalManualResults: false, generateReports: true, targetDatabases: targetDatabases, evidenceContext: _evidenceContext);
                // Saved here because the evidence is indexed before this run's directory exists.
                if (_evidenceContext != null) SQLAuditor.Lib.EvidenceStore.Save(_evidenceContext);
                ReportProviderFault();
                RegisterEvidenceResolvedItems(results);
                UpdateEvaluationProgressDisplay();
                LogPlatformSummary();
                Log($"Completed evaluation of {results.Length} checklist items. Results in results/ folder.");
                UpdateSummaryView(results);
                MessageBox.Show(this, "Evaluation completed successfully.", "Evaluation Complete", MessageBoxButton.OK, MessageBoxImage.Information);
                // checklist_results.json and the full five-file report suite are produced
                // automatically by the Auditor at the end of the assessment.
                Log($"Summary report generated at {UiFilePath(SqlAuditor.Reporting.ReportSuiteGenerator.AuditReportFileName)}");
            }
            catch (OperationCanceledException)
            {
                Log("Evaluation cancelled. Existing result files were left unchanged.");
            }
            catch (Exception ex)
            {
                Log("Error: " + ex.Message);
            }
            finally
            {
                _isEvaluating = false;
            }
        }

        private async void SubmitBtn_Click(object sender, RoutedEventArgs e)
        {
            if (_pendingUserInput != null && !_pendingUserInput.Task.IsCompleted)
            {
                var val = ManualOutputBox.Text ?? string.Empty;
                _pendingUserInput.TrySetResult(val);
                Log("Submitted manual evidence.");
                // advance to next manual item if any
                AdvanceManualIndex();
                return;
            }

            var item = GetCurrentManualItem();
            if (item == null)
            {
                Log("No pending manual checklist item selected.");
                return;
            }

            SaveCurrentManualDraft(false);
            var state = EnsureManualState(item.Id);

            // The reviewer states the decision inside the evidence text, e.g. "Fail - no topology document".
            var decision = ParseManualDecision(state.Remarks);
            if (decision == null)
            {
                MessageBox.Show(
                    "Start the input with your decision, 'Pass' or 'Fail', followed by the reason before submitting.",
                    "Manual Evaluation",
                    MessageBoxButton.OK,
                    MessageBoxImage.Warning);
                return;
            }

            state.SelectedOutcome = decision;
            state.IsSubmitted = true;
            await PersistManualResultAsync(item, state);

            if (_evalStatusMap != null)
            {
                _evalStatusMap[item.Id] = (NormalizeUiStatus(state.SelectedOutcome ?? string.Empty, "AI-Manual"), "AI-Manual");
            }

            UpdateManualActionButtonStates(state.SelectedOutcome, state.IsSubmitted);
            RenderEvaluationTree();
            Log($"Submitted manual evaluation for {item.Id} as {state.SelectedOutcome}.");
        }

        // Reads the verdict the reviewer led their evidence with. Scanning the whole sentence is
        // deliberately not done: "no failover test evidence" must not resolve to Fail.
        private static string? ParseManualDecision(string? text)
            => SQLAuditor.Lib.ManualVerdict.TryParse(text);

        private void PrevManualBtn_Click(object sender, RoutedEventArgs e)
        {
            if (_manualQueue == null || _manualQueue.Count == 0) return;
            SaveCurrentManualDraft(false);
            if (_manualIndex <= 0) _manualIndex = _manualQueue.Count - 1;
            else _manualIndex--;
            ShowManualAtIndex();
        }

        private void NextManualBtn_Click(object sender, RoutedEventArgs e)
        {
            if (_manualQueue == null || _manualQueue.Count == 0) return;
            SaveCurrentManualDraft(false);
            if (_manualIndex >= _manualQueue.Count - 1) _manualIndex = 0;
            else _manualIndex++;
            ShowManualAtIndex();
        }

        private void ShowManualAtIndex()
        {
            if (_manualQueue == null || _manualQueue.Count == 0 || _manualIndex < 0 || _manualIndex >= _manualQueue.Count)
            {
                ManualTitle.Text = "Manual steps";
                ManualStepsText.Text = string.Empty;
                _isHydratingManualUi = true;
                ManualOutputBox.Text = string.Empty;
                _isHydratingManualUi = false;
                UpdateManualActionButtonStates(null, false);
                return;
            }
            var it = _manualQueue[_manualIndex];
            var state = EnsureManualState(it.Id);
            // In a fleet run the same item id appears once per server, so the title has to name it.
            var serverSuffix = _serverUiStates.Count > 1 && _selectedServerKey != null
                ? $"  —  {_selectedServerKey}"
                : string.Empty;
            ManualTitle.Text = state.IsEvidenceResolved
                ? $"AI-resolved from evidence — {it.Id}{serverSuffix}"
                : $"Manual evaluation for {it.Id}{serverSuffix}";
            ManualStepsText.Text = state.IsEvidenceResolved
                ? ToPlainText(state.EvidenceSummary)
                : ToPlainText(state.Instructions);
            _isHydratingManualUi = true;
            ManualOutputBox.Text = state.Remarks;
            _isHydratingManualUi = false;
            UpdateManualActionButtonStates(state.SelectedOutcome, state.IsSubmitted);
        }

        // Items the evidence analyzer decided never pass through requestUserInput, so they are added
        // to the queue after the run - visible, attributed, and overridable rather than silently gone.
        private void RegisterEvidenceResolvedItems(System.Collections.Generic.IEnumerable<SQLAuditor.Lib.ChecklistResult> results)
        {
            if (_evalItemMap == null) return;

            var registered = 0;
            foreach (var result in results)
            {
                if (!SQLAuditor.Lib.EvidenceAttribution.IsEvidenceDerived(result.Evidence)) continue;
                if (!_evalItemMap.TryGetValue(result.Id, out var entry)) continue;

                InsertManualQueueItem(entry.Item);
                var state = EnsureManualState(result.Id);
                state.EvidenceSummary = BuildEvidenceSummary(result);
                state.SelectedOutcome = result.Outcome;
                state.IsSubmitted = true;
                state.Remarks = string.Empty;
                registered++;
            }

            if (registered == 0) return;

            if (_manualIndex < 0) _manualIndex = 0;
            Log($"{registered} item(s) were resolved from the attached evidence. They are listed under Manual steps with their cited files - use Override to replace any verdict with your own.");
            ShowManualAtIndex();
        }

        private static string BuildEvidenceSummary(SQLAuditor.Lib.ChecklistResult result)
        {
            var sb = new System.Text.StringBuilder();
            sb.Append("Checklist: ").Append(result.Id).Append(" - ").AppendLine(result.Description);
            sb.Append("Verdict recorded from evidence: ").AppendLine(result.Outcome);
            sb.AppendLine();
            sb.AppendLine("This item was NOT reviewed by a person. It was decided by reading the artefacts you attached.");
            sb.AppendLine("Check the cited files below. If you disagree, click Override and record your own verdict.");
            sb.AppendLine();
            if (!string.IsNullOrWhiteSpace(result.Finding))
            {
                sb.AppendLine("## Finding");
                sb.AppendLine(result.Finding.Trim());
                sb.AppendLine();
            }
            if (!string.IsNullOrWhiteSpace(result.Evidence))
            {
                sb.AppendLine("## Evidence and cited files");
                sb.AppendLine(result.Evidence.Trim());
            }
            return sb.ToString().TrimEnd();
        }

        private async void OverrideEvidenceBtn_Click(object sender, RoutedEventArgs e)
        {
            var item = GetCurrentManualItem();
            if (item == null) return;

            var state = EnsureManualState(item.Id);
            if (!state.IsEvidenceResolved) return;

            if (MessageBox.Show(
                    $"Discard the AI verdict for {item.Id} and review it yourself?",
                    "Override AI Verdict",
                    MessageBoxButton.OKCancel,
                    MessageBoxImage.Question) != MessageBoxResult.OK)
                return;

            // The reviewer needs the real verification steps, which were never generated for an
            // item the evidence settled.
            if (string.IsNullOrWhiteSpace(state.Instructions) && _auditor != null)
            {
                OverrideEvidenceBtn.IsEnabled = false;
                try
                {
                    state.Instructions = await _auditor.GenerateManualInstructionsAsync(item);
                    if (_manualInstructions != null) _manualInstructions[item.Id] = state.Instructions;
                }
                catch (Exception ex)
                {
                    Log($"Could not generate manual steps for {item.Id}: {ex.Message}");
                }
                finally
                {
                    OverrideEvidenceBtn.IsEnabled = true;
                }
            }

            state.EvidenceSummary = null;
            state.IsSubmitted = false;
            state.SelectedOutcome = null;
            state.Remarks = string.Empty;
            state.EnrichedResult = null;
            state.EnrichedKey = null;

            if (_evalStatusMap != null)
                _evalStatusMap[item.Id] = ("Pending Manual Evaluation", "AI-Manual");

            ShowManualAtIndex();
            RenderEvaluationTree();
            Log($"AI verdict for {item.Id} discarded. Enter your own decision and submit.");
        }

        // ManualStepsText is a TextBlock, so Markdown from the model would otherwise render as literal characters.
        private static string ToPlainText(string? markdown)
        {
            if (string.IsNullOrWhiteSpace(markdown)) return string.Empty;

            var sb = new System.Text.StringBuilder();
            foreach (var rawLine in markdown.Replace("\r\n", "\n").Split('\n'))
            {
                var line = rawLine.TrimEnd();
                if (line.TrimStart().StartsWith("```", StringComparison.Ordinal)) continue;

                line = System.Text.RegularExpressions.Regex.Replace(line, @"^\s*>\s?", string.Empty);
                if (System.Text.RegularExpressions.Regex.IsMatch(line, @"^\s*([-*_])\1{2,}\s*$")) continue;
                line = System.Text.RegularExpressions.Regex.Replace(line, @"^\s*#{1,6}\s*", string.Empty);
                line = System.Text.RegularExpressions.Regex.Replace(line, @"^(\s*)[-*+]\s+", "$1\u2022 ");
                line = System.Text.RegularExpressions.Regex.Replace(line, @"\*\*(.+?)\*\*", "$1");
                line = System.Text.RegularExpressions.Regex.Replace(line, @"__(.+?)__", "$1");
                line = System.Text.RegularExpressions.Regex.Replace(line, @"`([^`]+)`", "$1");

                sb.AppendLine(line);
            }

            return sb.ToString().Trim();
        }

        private bool HasPendingManualResponses()
        {
            if (_evalStatusMap == null)
            {
                return false;
            }

            foreach (var kv in _evalStatusMap)
            {
                if (!string.Equals(kv.Value.Technique, "AI-Manual", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                if (_manualStateMap == null || !_manualStateMap.TryGetValue(kv.Key, out var state) || state == null)
                {
                    return true;
                }

                if (!state.IsSubmitted)
                {
                    return true;
                }
            }

            return _evalStatusMap.Values.Any(v =>
                string.Equals(v.Status, "Pending Manual Evaluation", StringComparison.OrdinalIgnoreCase)
                || string.Equals(v.Status, "Generating Manual Plan", StringComparison.OrdinalIgnoreCase)
                || string.Equals(v.Status, "Evaluating", StringComparison.OrdinalIgnoreCase)
                || string.Equals(v.Status, "Not Started", StringComparison.OrdinalIgnoreCase));
        }

        private ChecklistResult[] LoadSummaryResultsFromDisk()
        {
            try
            {
                var path = UiFilePath("checklist_results.json");
                if (!System.IO.File.Exists(path)) return Array.Empty<ChecklistResult>();
                var txt = System.IO.File.ReadAllText(path);
                return JsonSerializer.Deserialize<ChecklistResult[]>(txt) ?? Array.Empty<ChecklistResult>();
            }
            catch
            {
                return Array.Empty<ChecklistResult>();
            }
        }

        private System.Collections.Generic.List<ManualCheckExportRow> GetManualChecksForExport()
        {
            var rows = new System.Collections.Generic.List<ManualCheckExportRow>();
            if (_evalItemMap == null || _evalStatusMap == null) return rows;

            var persisted = LoadSummaryResultsFromDisk()
                .GroupBy(result => result.Id, StringComparer.OrdinalIgnoreCase)
                .ToDictionary(group => group.Key, group => group.First(), StringComparer.OrdinalIgnoreCase);

            foreach (var pair in _evalItemMap.OrderBy(entry => entry.Value.Item.Id, System.Collections.Generic.Comparer<string>.Create(CompareChecklistIds)))
            {
                if (!_evalStatusMap.TryGetValue(pair.Key, out var statusEntry)
                    || !HistoricalManualResultsStore.IsManualTechnique(statusEntry.Technique))
                {
                    continue;
                }

                ManualEvaluationState? state = null;
                _manualStateMap?.TryGetValue(pair.Key, out state);
                persisted.TryGetValue(pair.Key, out var persistedResult);

                var instructions = state?.Instructions ?? string.Empty;
                if (string.IsNullOrWhiteSpace(instructions)
                    && _manualInstructions != null
                    && _manualInstructions.TryGetValue(pair.Key, out var generatedInstructions))
                {
                    instructions = generatedInstructions;
                }

                rows.Add(new ManualCheckExportRow
                {
                    Id = pair.Value.Item.Id,
                    Area = pair.Value.Area,
                    Description = pair.Value.Item.Description,
                    Verification = pair.Value.Item.Verification,
                    ManualSteps = instructions,
                    Status = statusEntry.Status,
                    Decision = state?.SelectedOutcome
                        ?? (persistedResult != null && HistoricalManualResultsStore.IsCompletedOutcome(persistedResult.Outcome)
                            ? persistedResult.Outcome
                            : string.Empty),
                    Evidence = state?.Remarks ?? persistedResult?.Evidence ?? string.Empty,
                });
            }

            return rows;
        }

        private System.Collections.Generic.HashSet<string> GetUnresolvedManualCheckIds()
        {
            var unresolved = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (_evalItemMap == null || _evalStatusMap == null) return unresolved;

            foreach (var pair in _evalItemMap)
            {
                if (!_evalStatusMap.TryGetValue(pair.Key, out var statusEntry)
                    || !HistoricalManualResultsStore.IsManualTechnique(statusEntry.Technique)
                    || _copiedManualIds.Contains(pair.Key))
                {
                    continue;
                }

                var status = statusEntry.Status ?? string.Empty;
                if (SQLAuditor.Lib.SkippedEvaluation.IsSkippedOutcome(status)
                    || SQLAuditor.Lib.NotApplicableEvidence.IsNotApplicableOutcome(status))
                {
                    continue;
                }

                if (_manualStateMap != null
                    && _manualStateMap.TryGetValue(pair.Key, out var state)
                    && state.IsSubmitted)
                {
                    continue;
                }

                unresolved.Add(pair.Key);
            }

            return unresolved;
        }

        private async Task<(int Applied, int Ignored)> ApplyImportedManualChecksAsync(
            System.Collections.Generic.IEnumerable<ManualCheckImportRow> importedRows)
        {
            if (_evalItemMap == null || _evalStatusMap == null) return (0, importedRows.Count());

            var appliedIds = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var ignored = 0;
            foreach (var imported in importedRows)
            {
                // The CSV is the source of truth for manual decisions: rows for valid manual checks
                // in the current run are always applied, overwriting any existing decision including
                // ones already submitted or reused via "Copy last run for the manual items".
                if (!_evalItemMap.TryGetValue(imported.Id, out var pair)
                    || !_evalStatusMap.TryGetValue(imported.Id, out var statusEntry)
                    || !HistoricalManualResultsStore.IsManualTechnique(statusEntry.Technique))
                {
                    ignored++;
                    continue;
                }

                // A decision copied from a previous run is now being overwritten by the CSV, so the
                // item must no longer be treated as reused; otherwise reporting would keep the copy.
                _copiedManualIds.Remove(imported.Id);

                var state = EnsureManualState(imported.Id);
                if (string.IsNullOrWhiteSpace(state.Instructions) && !string.IsNullOrWhiteSpace(imported.ManualSteps))
                    state.Instructions = imported.ManualSteps;
                state.SelectedOutcome = imported.Decision;
                state.Remarks = imported.Evidence;
                state.IsSubmitted = true;
                state.EnrichedResult = null;
                state.EnrichedKey = null;

                await PersistManualResultAsync(pair.Item, state);
                _evalStatusMap[imported.Id] = (
                    string.Equals(imported.Decision, "Pass", StringComparison.OrdinalIgnoreCase) ? "Passed" : "Failed",
                    "AI-Manual");
                appliedIds.Add(imported.Id);
            }

            _manualQueue?.RemoveAll(item => appliedIds.Contains(item.Id));
            if (_manualQueue == null || _manualQueue.Count == 0)
                _manualIndex = -1;
            else if (_manualIndex >= _manualQueue.Count)
                _manualIndex = _manualQueue.Count - 1;

            ShowManualAtIndex();
            RenderEvaluationTree();
            return (appliedIds.Count, ignored);
        }

        private int MarkPendingManualAsSkipped(
            System.Collections.Generic.IReadOnlyCollection<string> pendingIds,
            string csvPath)
        {
            if (pendingIds.Count == 0) return 0;
            if (_evalItemMap == null) return 0;

            var path = UiFilePath("checklist_results.json");
            var exportedFileName = System.IO.Path.GetFileName(csvPath);
            var skippedCount = 0;

            lock (SQLAuditor.Lib.Auditor.ResultsFileLockFor(UiRunDirectory))
            {
                var list = System.IO.File.Exists(path)
                    ? JsonSerializer.Deserialize<System.Collections.Generic.List<SQLAuditor.Lib.ChecklistResult>>(System.IO.File.ReadAllText(path))
                        ?? new System.Collections.Generic.List<SQLAuditor.Lib.ChecklistResult>()
                    : new System.Collections.Generic.List<SQLAuditor.Lib.ChecklistResult>();

                foreach (var id in pendingIds)
                {
                    if (!_evalItemMap.TryGetValue(id, out var pair)) continue;
                    var item = pair.Item;
                    var evidence = $"Manual evaluation was skipped for this report. Verification steps were exported to {exportedFileName} for offline completion.";
                    var skippedResult = SQLAuditor.Lib.ChecklistResultEnricher.Enrich(
                        new SQLAuditor.Lib.ChecklistResult(
                            item.Id,
                            item.Description,
                            item.Verification,
                            SQLAuditor.Lib.SkippedEvaluation.Outcome,
                            evidence,
                            item.ScriptFile,
                            "AI-Manual"));
                    var index = list.FindIndex(result => string.Equals(result.Id, item.Id, StringComparison.OrdinalIgnoreCase));
                    if (index >= 0) list[index] = skippedResult;
                    else list.Add(skippedResult);
                    skippedCount++;

                    if (_evalStatusMap != null)
                    {
                        _evalStatusMap[item.Id] = (SQLAuditor.Lib.SkippedEvaluation.Outcome, "AI-Manual");
                    }
                }

                System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
                System.IO.File.WriteAllText(path, JsonSerializer.Serialize(list, new JsonSerializerOptions { WriteIndented = true }));
            }

            _manualQueue?.RemoveAll(item => pendingIds.Contains(item.Id));
            if (_manualQueue == null || _manualQueue.Count == 0)
            {
                _manualIndex = -1;
            }
            else if (_manualIndex >= _manualQueue.Count)
            {
                _manualIndex = _manualQueue.Count - 1;
            }
            ShowManualAtIndex();
            RenderEvaluationTree();
            return skippedCount;
        }

        private void UpdateSummaryView(System.Collections.Generic.IReadOnlyCollection<ChecklistResult> results)
        {
            var resultList = results?.ToList() ?? new System.Collections.Generic.List<ChecklistResult>();
            var total = resultList.Count;
            var passed = resultList.Count(r => string.Equals(r.Outcome, "Pass", StringComparison.OrdinalIgnoreCase));
            var failed = resultList.Count(r => string.Equals(r.Outcome, "Fail", StringComparison.OrdinalIgnoreCase));
            var review = resultList.Count(r => string.Equals(r.Outcome, "NeedsReview", StringComparison.OrdinalIgnoreCase));
            var skipped = resultList.Count(r => SQLAuditor.Lib.SkippedEvaluation.IsSkippedOutcome(r.Outcome));
            var script = resultList.Count(r => string.Equals(r.Technique, "Script", StringComparison.OrdinalIgnoreCase));
            var mcp = resultList.Count(r => string.Equals(r.Technique, "AI-MCP", StringComparison.OrdinalIgnoreCase));
            var manual = resultList.Count(r => string.Equals(r.Technique, "AI-Manual", StringComparison.OrdinalIgnoreCase));

            if (SummaryTotalText != null) SummaryTotalText.Text = total.ToString();
            if (SummaryPassedText != null) SummaryPassedText.Text = passed.ToString();
            if (SummaryFailedText != null) SummaryFailedText.Text = failed.ToString();
            if (SummaryReviewText != null) SummaryReviewText.Text = review.ToString();

            if (SummaryList != null)
            {
                SummaryList.ItemsSource = resultList
                    .Select(r => new SummaryResultRow
                    {
                        Id = r.Id ?? string.Empty,
                        Description = r.Description ?? string.Empty,
                        Outcome = r.Outcome ?? string.Empty,
                        Technique = r.Technique ?? string.Empty
                    })
                    .ToList();
            }

            if (SummaryOutcomeChartItems != null)
            {
                SummaryOutcomeChartItems.ItemsSource = new[]
                {
                    new SummaryMetricItem { Label = "Passed", Value = passed, Total = Math.Max(total, 1), Detail = "Items marked Pass", BarBrush = System.Windows.Media.Brushes.ForestGreen },
                    new SummaryMetricItem { Label = "Failed", Value = failed, Total = Math.Max(total, 1), Detail = "Items marked Fail", BarBrush = System.Windows.Media.Brushes.IndianRed },
                    new SummaryMetricItem { Label = "Needs Review", Value = review, Total = Math.Max(total, 1), Detail = "Items requiring follow-up", BarBrush = System.Windows.Media.Brushes.Goldenrod },
                    new SummaryMetricItem { Label = "Skipped", Value = skipped, Total = Math.Max(total, 1), Detail = "Exported and excluded from scoring", BarBrush = System.Windows.Media.Brushes.SlateGray }
                };
            }

            if (SummaryTechniqueChartItems != null)
            {
                SummaryTechniqueChartItems.ItemsSource = new[]
                {
                    new SummaryMetricItem { Label = "Script", Value = script, Total = Math.Max(total, 1), Detail = "Script-based checks", BarBrush = System.Windows.Media.Brushes.SteelBlue },
                    new SummaryMetricItem { Label = "AI-MCP", Value = mcp, Total = Math.Max(total, 1), Detail = "MCP-evaluated checks", BarBrush = System.Windows.Media.Brushes.MediumPurple },
                    new SummaryMetricItem { Label = "AI-Manual", Value = manual, Total = Math.Max(total, 1), Detail = "Pending/Manual checks", BarBrush = System.Windows.Media.Brushes.OrangeRed }
                };
            }
        }

        private string NormalizeUiStatus(string outcome, string technique)
        {
            if (string.Equals(technique, "AI-Manual", StringComparison.OrdinalIgnoreCase) && string.Equals(outcome, "Evaluating", StringComparison.OrdinalIgnoreCase)) return "Generating Manual Plan";
            if (string.Equals(outcome, "Evaluating", StringComparison.OrdinalIgnoreCase)) return "Evaluating";
            if (string.Equals(outcome, "Pass", StringComparison.OrdinalIgnoreCase) || string.Equals(outcome, "Passed", StringComparison.OrdinalIgnoreCase)) return "Passed";
            if (string.Equals(technique, "AI-Manual", StringComparison.OrdinalIgnoreCase) && string.Equals(outcome, "NeedsReview", StringComparison.OrdinalIgnoreCase)) return "Pending Manual Evaluation";
            // Any other NeedsReview means the tool could not assess the item. Falling through to
            // "Failed" reported that as a control gap and disagreed with checklist_results.json.
            if (string.Equals(outcome, "NeedsReview", StringComparison.OrdinalIgnoreCase)) return "Needs Review";
            if (SQLAuditor.Lib.SkippedEvaluation.IsSkippedOutcome(outcome)) return SQLAuditor.Lib.SkippedEvaluation.Outcome;
            if (SQLAuditor.Lib.NotApplicableEvidence.IsNotApplicableOutcome(outcome)) return "Not Applicable";
            if (string.Equals(outcome, "Not Started", StringComparison.OrdinalIgnoreCase)) return "Not Started";
            return "Failed";
        }

        private System.Windows.Media.Brush GetStatusBrush(string status)
        {
            if (string.Equals(status, "Passed", StringComparison.OrdinalIgnoreCase)) return System.Windows.Media.Brushes.ForestGreen;
            if (string.Equals(status, "Evaluating", StringComparison.OrdinalIgnoreCase)) return System.Windows.Media.Brushes.DarkOrange;
            if (string.Equals(status, "Generating Manual Plan", StringComparison.OrdinalIgnoreCase)) return System.Windows.Media.Brushes.DodgerBlue;
            if (string.Equals(status, "Pending Manual Evaluation", StringComparison.OrdinalIgnoreCase)) return System.Windows.Media.Brushes.Goldenrod;
            if (string.Equals(status, "Needs Review", StringComparison.OrdinalIgnoreCase)) return System.Windows.Media.Brushes.Goldenrod;
            if (SQLAuditor.Lib.SkippedEvaluation.IsSkippedOutcome(status)) return System.Windows.Media.Brushes.SlateGray;
            if (string.Equals(status, "Not Started", StringComparison.OrdinalIgnoreCase)) return System.Windows.Media.Brushes.DimGray;
            if (string.Equals(status, "Not Applicable", StringComparison.OrdinalIgnoreCase)) return System.Windows.Media.Brushes.SlateGray;
            return System.Windows.Media.Brushes.IndianRed;
        }

        // Queues one rebuild at background priority instead of rendering synchronously on every
        // engine progress event, so status updates never monopolise the dispatcher.
        private void RequestEvaluationTreeRender()
        {
            if (_treeRenderQueued) return;
            _treeRenderQueued = true;
            this.Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Background, new Action(() =>
            {
                _treeRenderQueued = false;
                RenderEvaluationTree();
                UpdateEvaluationProgressDisplay();
            }));
        }

        private static bool IsTerminalEvaluationStatus(string status)
        {
            return string.Equals(status, "Passed", StringComparison.OrdinalIgnoreCase)
                || string.Equals(status, "Failed", StringComparison.OrdinalIgnoreCase)
                || string.Equals(status, "Skipped", StringComparison.OrdinalIgnoreCase)
                || string.Equals(status, "Not Applicable", StringComparison.OrdinalIgnoreCase)
                || string.Equals(status, "Pending Manual Evaluation", StringComparison.OrdinalIgnoreCase)
                || string.Equals(status, "Needs Review", StringComparison.OrdinalIgnoreCase)
                || string.Equals(status, "Complete", StringComparison.OrdinalIgnoreCase)
                || string.Equals(status, "Completed", StringComparison.OrdinalIgnoreCase)
                || string.Equals(status, "Error", StringComparison.OrdinalIgnoreCase);
        }

        private void UpdateEvaluationProgressDisplay()
        {
            // A fleet run counts every server's items so the bar reflects the whole batch.
            if (_serverUiStates.Count > 1)
            {
                var fleetTotal = _serverUiStates.Values.Sum(s => s.EvalItemMap.Count);
                var fleetDone = _serverUiStates.Values.Sum(s => s.EvalStatusMap.Count(kvp =>
                    s.EvalItemMap.ContainsKey(kvp.Key) && IsTerminalEvaluationStatus(kvp.Value.Status)));

                EvalProgressBar.Minimum = 0;
                EvalProgressBar.Maximum = Math.Max(fleetTotal, 1);
                EvalProgressBar.Value = Math.Min(fleetDone, Math.Max(fleetTotal, 1));
                EvalProgressText.Text = $"{fleetDone} / {fleetTotal} across {_serverUiStates.Count} servers";
                return;
            }

            if (_evalItemMap == null || _evalStatusMap == null)
            {
                EvalProgressBar.Value = 0;
                EvalProgressBar.Maximum = 1;
                EvalProgressText.Text = "0 / 0";
                return;
            }

            var total = _evalItemMap.Count;
            var finished = _evalStatusMap.Count(kvp => _evalItemMap.ContainsKey(kvp.Key) && IsTerminalEvaluationStatus(kvp.Value.Status));
            var max = Math.Max(total, 1);

            EvalProgressBar.Minimum = 0;
            EvalProgressBar.Maximum = max;
            EvalProgressBar.Value = Math.Min(finished, max);
            EvalProgressText.Text = $"{finished} / {total}";
        }

        private void RenderEvaluationTree()
        {
            // A fleet run shows every server at once: server -> technique -> area -> sub-area -> item.
            if (_serverUiStates.Count > 1)
            {
                EvalTree.Items.Clear();
                foreach (var entry in _servers)
                {
                    if (!_serverUiStates.TryGetValue(entry.DisplayName, out var state)) continue;

                    var done = state.EvalStatusMap.Count(kvp =>
                        state.EvalItemMap.ContainsKey(kvp.Key) && IsTerminalEvaluationStatus(kvp.Value.Status));
                    var serverNode = new System.Windows.Controls.TreeViewItem
                    {
                        Header = BuildServerNodeHeader(entry, done, state.EvalItemMap.Count),
                        IsExpanded = true,
                        Tag = entry.DisplayName,
                    };

                    foreach (var node in BuildTechniqueNodes(state.EvalItemMap, state.EvalStatusMap))
                    {
                        serverNode.Items.Add(node);
                    }

                    EvalTree.Items.Add(serverNode);
                }
                return;
            }

            if (_evalItemMap == null || _evalStatusMap == null) return;
            EvalTree.Items.Clear();
            foreach (var node in BuildTechniqueNodes(_evalItemMap, _evalStatusMap))
            {
                EvalTree.Items.Add(node);
            }
        }

        private object BuildServerNodeHeader(ServerEntry entry, int finished, int total)
        {
            var text = new System.Windows.Controls.TextBlock();
            text.Inlines.Add(new System.Windows.Documents.Run($"{entry.DisplayName} ")
            {
                FontWeight = FontWeights.Bold
            });
            text.Inlines.Add(new System.Windows.Documents.Run($"[{entry.Status}] ")
            {
                Foreground = GetStatusBrush(entry.Status),
                FontWeight = FontWeights.SemiBold
            });
            text.Inlines.Add(new System.Windows.Documents.Run($"{finished} / {total} items"));
            return text;
        }

        private System.Collections.Generic.List<System.Windows.Controls.TreeViewItem> BuildTechniqueNodes(
            System.Collections.Generic.Dictionary<string, (string Area, SQLAuditor.Lib.ChecklistItem Item)> evalItemMap,
            System.Collections.Generic.Dictionary<string, (string Status, string Technique)> evalStatusMap)
        {
            var nodes = new System.Collections.Generic.List<System.Windows.Controls.TreeViewItem>();
            var techniqueOrder = new[] { "Script", "AI-MCP", "AI-Manual" };

            foreach (var technique in techniqueOrder)
            {
                var techniqueItems = evalItemMap
                    .Where(kv => evalStatusMap.TryGetValue(kv.Key, out var state) && string.Equals(state.Technique, technique, StringComparison.OrdinalIgnoreCase))
                    .Select(kv => kv.Value)
                    .OrderBy(v => v.Item.Id, System.Collections.Generic.Comparer<string>.Create(CompareChecklistIds))
                    .ToList();

                if (techniqueItems.Count == 0) continue;

                var techniqueNode = new System.Windows.Controls.TreeViewItem { Header = $"{technique} ({techniqueItems.Count} items)", IsExpanded = true };

                var byArea = techniqueItems
                    .GroupBy(x => GetChecklistAreaId(x.Item.Id))
                    .OrderBy(g => g.Key, System.Collections.Generic.Comparer<string>.Create(CompareChecklistIds));

                foreach (var areaGrp in byArea)
                {
                    var areaTitle = areaGrp.FirstOrDefault().Area;
                    var areaNode = new System.Windows.Controls.TreeViewItem { Header = FormatAreaLabel(areaGrp.Key, areaTitle), IsExpanded = true };

                    var bySubArea = areaGrp
                        .GroupBy(x => GetChecklistSubAreaId(x.Item.Id))
                        .OrderBy(g => g.Key, System.Collections.Generic.Comparer<string>.Create(CompareChecklistIds));

                    foreach (var subAreaGrp in bySubArea)
                    {
                        var subAreaTitle = subAreaGrp.FirstOrDefault().Item.Category;
                        var subAreaNode = new System.Windows.Controls.TreeViewItem { Header = FormatSubAreaLabel(subAreaGrp.Key, subAreaTitle), IsExpanded = true };

                        foreach (var pair in subAreaGrp.OrderBy(x => x.Item.Id, System.Collections.Generic.Comparer<string>.Create(CompareChecklistIds)))
                        {
                            var status = evalStatusMap.TryGetValue(pair.Item.Id, out var st) ? st.Status : "Not Started";
                            var statusBrush = GetStatusBrush(status);
                            var text = new System.Windows.Controls.TextBlock();
                            text.Inlines.Add(new System.Windows.Documents.Run($"[{status}] ")
                            {
                                Foreground = statusBrush,
                                FontWeight = FontWeights.SemiBold
                            });
                            text.Inlines.Add(new System.Windows.Documents.Run($"{pair.Item.Id} {pair.Item.Description}"));

                            var itemNode = new System.Windows.Controls.TreeViewItem
                            {
                                Header = text,
                                Tag = pair.Item,
                                IsExpanded = true
                            };
                            subAreaNode.Items.Add(itemNode);
                        }

                        areaNode.Items.Add(subAreaNode);
                    }

                    techniqueNode.Items.Add(areaNode);
                }

                nodes.Add(techniqueNode);
            }

            return nodes;
        }

        private string EvaluateManualOutcome(string response)
            => SQLAuditor.Lib.ManualVerdict.Normalize(response)
               ?? SQLAuditor.Lib.ManualVerdict.Parse(response);

        private async Task ApplyDeferredManualDecisionAsync(string response)
        {
            try
            {
                var item = GetCurrentManualItem();
                if (item == null)
                {
                    Log("No pending manual checklist item selected.");
                    return;
                }

                SaveCurrentManualDraft(false);
                var state = EnsureManualState(item.Id);
                var outcome = EvaluateManualOutcome(response);
                state.SelectedOutcome = outcome;
                state.IsSubmitted = true;

                var status = NormalizeUiStatus(outcome, "AI-Manual");
                if (_evalStatusMap != null)
                {
                    _evalStatusMap[item.Id] = (status, "AI-Manual");
                }
                RenderEvaluationTree();
                await PersistManualResultAsync(item, state);
                UpdateManualActionButtonStates(state.SelectedOutcome, state.IsSubmitted);
                Log($"Stored deferred manual result for {item.Id}: {outcome}");

            }
            catch (Exception ex)
            {
                Log("Failed to store deferred manual decision: " + ex.Message);
            }
        }

        private SQLAuditor.Lib.ChecklistItem? GetCurrentManualItem()
        {
            if (_manualQueue == null || _manualQueue.Count == 0 || _manualIndex < 0 || _manualIndex >= _manualQueue.Count)
            {
                return null;
            }

            return _manualQueue[_manualIndex];
        }

        // Manual guidance now arrives in completion order, but the reviewer steps through the queue
        // by index, so each item is placed at its checklist position instead of being appended.
        private void InsertManualQueueItem(SQLAuditor.Lib.ChecklistItem item)
        {
            _manualQueue ??= new System.Collections.Generic.List<SQLAuditor.Lib.ChecklistItem>();
            if (_manualQueue.Any(m => string.Equals(m.Id, item.Id, StringComparison.OrdinalIgnoreCase))) return;

            var order = ChecklistOrderOf(item.Id);
            var position = _manualQueue.Count;
            for (var i = 0; i < _manualQueue.Count; i++)
            {
                if (ChecklistOrderOf(_manualQueue[i].Id) > order)
                {
                    position = i;
                    break;
                }
            }

            _manualQueue.Insert(position, item);

            // Keep the reviewer on the item they are currently looking at.
            if (_manualIndex >= position) _manualIndex++;
        }

        private int ChecklistOrderOf(string id) =>
            _checklistOrder != null && _checklistOrder.TryGetValue(id, out var index) ? index : int.MaxValue;

        private ManualEvaluationState EnsureManualState(string itemId)
        {
            if (_manualStateMap == null)
            {
                _manualStateMap = new System.Collections.Generic.Dictionary<string, ManualEvaluationState>();
            }

            if (!_manualStateMap.TryGetValue(itemId, out var state))
            {
                state = new ManualEvaluationState();
                _manualStateMap[itemId] = state;
            }

            if (string.IsNullOrEmpty(state.Instructions) && _manualInstructions != null && _manualInstructions.TryGetValue(itemId, out var inst))
            {
                state.Instructions = inst ?? string.Empty;
            }

            return state;
        }

        private void SaveCurrentManualDraft(bool resetSubmitted)
        {
            if (_isHydratingManualUi)
            {
                return;
            }

            var item = GetCurrentManualItem();
            if (item == null)
            {
                return;
            }

            var state = EnsureManualState(item.Id);
            var remarks = ManualOutputBox.Text ?? string.Empty;
            var changed = !string.Equals(state.Remarks, remarks, StringComparison.Ordinal);
            state.Remarks = remarks;

            if (changed && resetSubmitted && state.IsSubmitted)
            {
                state.IsSubmitted = false;
                if (_evalStatusMap != null)
                {
                    _evalStatusMap[item.Id] = ("Pending Manual Evaluation", "AI-Manual");
                    RenderEvaluationTree();
                }
            }

            UpdateManualActionButtonStates(state.SelectedOutcome, state.IsSubmitted);
        }

        private async Task PersistManualResultAsync(
            SQLAuditor.Lib.ChecklistItem item,
            ManualEvaluationState state,
            bool forceWrite = false)
        {
            // The reviewer's verdict is authoritative. Collapsing it to Pass/Fail here is what
            // silently filed Not Applicable decisions as control gaps.
            var outcome = SQLAuditor.Lib.ManualVerdict.Normalize(state.SelectedOutcome)
                ?? SQLAuditor.Lib.ManualVerdict.NeedsReview;
            var isNotApplicable = SQLAuditor.Lib.NotApplicableEvidence.IsNotApplicableOutcome(outcome);
            var key = outcome + "\u0001" + state.Remarks;

            await _manualPersistLock.WaitAsync();
            try
            {
                SQLAuditor.Lib.ChecklistResult updated;
                if (state.EnrichedResult != null && string.Equals(state.EnrichedKey, key, StringComparison.Ordinal))
                {
                    updated = state.EnrichedResult;
                }
                else
                {
                    // A Not Applicable item is outside the scored population, so no AI wording is
                    // authored for it - the reviewer's justification is the evidence of record.
                    if (_auditor != null && !isNotApplicable)
                    {
                        Log($"Reviewing manual evidence for {item.Id}...");
                        updated = await _auditor.BuildManualResultAsync(item, outcome, state.Instructions, state.Remarks);
                    }
                    else
                    {
                        var evidence = isNotApplicable
                            ? $"{SQLAuditor.Lib.NotApplicableEvidence.Marker}. {state.Remarks}"
                            : $"Manual Steps:\n{state.Instructions}\n\nOperator Remarks:\n{state.Remarks}\n\nSelected Outcome:\n{outcome}";
                        var seed = new SQLAuditor.Lib.ChecklistResult(item.Id, item.Description, item.Verification, outcome, evidence, item.ScriptFile, "AI-Manual");
                        if (isNotApplicable)
                            seed = seed with { NotApplicable = true, NotApplicableJustification = state.Remarks };
                        updated = SQLAuditor.Lib.ChecklistResultEnricher.Enrich(seed);
                    }

                    state.EnrichedResult = updated;
                    state.EnrichedKey = key;
                }

                if (forceWrite || !_isEvaluating)
                    WriteManualResultToDisk(updated, UiFilePath("checklist_results.json"));
            }
            catch (Exception ex)
            {
                Log($"Failed to save manual result for {item.Id}: {ex.Message}");
            }
            finally
            {
                _manualPersistLock.Release();
            }
        }

        private static void WriteManualResultToDisk(SQLAuditor.Lib.ChecklistResult updated, string path)
        {
            // The engine writes this same file from its own thread at the end of a run.
            lock (SQLAuditor.Lib.Auditor.ResultsFileLockFor(System.IO.Path.GetDirectoryName(path)!))
            {
                var list = new System.Collections.Generic.List<SQLAuditor.Lib.ChecklistResult>();
                if (System.IO.File.Exists(path))
                {
                    try { list = JsonSerializer.Deserialize<System.Collections.Generic.List<SQLAuditor.Lib.ChecklistResult>>(System.IO.File.ReadAllText(path)) ?? new System.Collections.Generic.List<SQLAuditor.Lib.ChecklistResult>(); } catch { list = new System.Collections.Generic.List<SQLAuditor.Lib.ChecklistResult>(); }
                }

                var idx = list.FindIndex(x => string.Equals(x.Id, updated.Id, StringComparison.OrdinalIgnoreCase));
                if (idx >= 0) list[idx] = updated;
                else list.Add(updated);

                System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
                System.IO.File.WriteAllText(path, JsonSerializer.Serialize(list, new JsonSerializerOptions { WriteIndented = true }));
            }
        }

        // Writes operator-submitted manual Pass/Fail decisions after the engine has persisted
        // the complete run. During evaluation they remain in memory, so cancellation cannot
        // mix new manual rows into an earlier checklist_results.json.
        private async Task ReapplySubmittedManualResultsAsync()
        {
            if (_manualQueue == null || _manualStateMap == null) return;
            foreach (var item in _manualQueue)
            {
                if (_manualStateMap.TryGetValue(item.Id, out var state)
                    && state.IsSubmitted
                    // An evidence-derived result already carries its attribution; rebuilding it
                    // here would overwrite the cited files with reviewer-shaped wording.
                    && !state.IsEvidenceResolved
                    && SQLAuditor.Lib.ManualVerdict.IsDecided(state.SelectedOutcome))
                {
                    await PersistManualResultAsync(item, state, forceWrite: true);
                }
            }
        }

        private System.Collections.Generic.IReadOnlyCollection<ChecklistResult>? LoadPersistedResults()
        {
            var path = UiFilePath("checklist_results.json");
            if (!System.IO.File.Exists(path)) return null;
            try
            {
                return JsonSerializer.Deserialize<System.Collections.Generic.List<ChecklistResult>>(System.IO.File.ReadAllText(path));
            }
            catch { return null; }
        }

        // Regenerates the five-file report suite from the current checklist_results.json
        // so every artifact reflects re-applied manual decisions
        // instead of the engine's placeholder write. Report generation is also when
        // historical_last_run.json is refreshed with newly evaluated manual results.
        private void RegenerateReportFromPersisted()
        {
            try
            {
                // A fleet run must refresh every server: a manual decision recorded after the batch
                // finished only lands in the server it was made against.
                if (_serverUiStates.Count > 1)
                {
                    foreach (var state in _serverUiStates.Values)
                    {
                        if (string.IsNullOrWhiteSpace(state.RunDirectory)) continue;
                        var serverMessage = SQLAuditor.Lib.Auditor.GenerateReports(runDirectory: state.RunDirectory);
                        if (!string.IsNullOrWhiteSpace(serverMessage))
                            Log($"[{state.DisplayName}] " + serverMessage.Replace(Environment.NewLine, " | "));
                    }
                    RefreshHistoricalManualAvailability();

                    // Consolidated artifacts are rebuilt from the per-server results that were just
                    // refreshed, so they always agree with them.
                    if (!string.IsNullOrWhiteSpace(_batchDirectory))
                    {
                        foreach (var batchMessage in SQLAuditor.Lib.BatchReportGenerator.Generate(_batchDirectory))
                            Log($"[consolidated] {batchMessage}");
                    }
                    return;
                }

                var message = SQLAuditor.Lib.Auditor.GenerateReports(runDirectory: _uiRunDirectory);
                if (!string.IsNullOrWhiteSpace(message)) Log(message.Replace(Environment.NewLine, " | "));
                RefreshHistoricalManualAvailability();
            }
            catch (Exception ex) { Log("Failed to regenerate reports: " + ex.Message); }
        }

        private void UpdateManualActionButtonStates(string? selectedOutcome, bool isSubmitted)
        {
            if (SubmitBtn == null || ManualOutputBox == null)
            {
                return;
            }

            var item = GetCurrentManualItem();
            var state = item == null ? null : EnsureManualState(item.Id);
            var isEvidenceResolved = state?.IsEvidenceResolved == true;

            if (OverrideEvidenceBtn != null)
                OverrideEvidenceBtn.Visibility = isEvidenceResolved ? Visibility.Visible : Visibility.Collapsed;

            // While the AI verdict stands there is nothing for the reviewer to submit; Override
            // is the way back into the normal manual flow.
            var isEnabled = IsCurrentManualReadyForInput() && !isEvidenceResolved;
            SubmitBtn.IsEnabled = isEnabled;
            ManualOutputBox.IsEnabled = isEnabled;

            SubmitBtn.Opacity = isSubmitted ? 1.0 : 0.85;
            SubmitBtn.BorderThickness = isSubmitted ? new Thickness(3) : new Thickness(1);
            SubmitBtn.Content = isEvidenceResolved ? "AI-resolved" : (isSubmitted ? "Submitted" : "Submit");
        }

        private bool IsCurrentManualReadyForInput()
        {
            var item = GetCurrentManualItem();
            if (item == null)
            {
                return false;
            }

            return true;
        }

        private string? GetCurrentManualSelectedOutcome()
        {
            var item = GetCurrentManualItem();
            if (item == null || _manualStateMap == null || !_manualStateMap.TryGetValue(item.Id, out var state) || state == null)
            {
                return null;
            }

            return state.SelectedOutcome;
        }

        private bool IsCurrentManualSubmitted()
        {
            var item = GetCurrentManualItem();
            if (item == null || _manualStateMap == null || !_manualStateMap.TryGetValue(item.Id, out var state) || state == null)
            {
                return false;
            }

            return state.IsSubmitted;
        }

        private System.Collections.Generic.List<string> GetIncompleteEvaluationMessages()
        {
            var messages = new System.Collections.Generic.List<string>();
            if (_evalItemMap == null || _evalStatusMap == null)
            {
                return messages;
            }

            foreach (var pair in _evalItemMap.OrderBy(x => x.Value.Item.Id, System.Collections.Generic.Comparer<string>.Create(CompareChecklistIds)))
            {
                var item = pair.Value.Item;
                if (!_evalStatusMap.TryGetValue(item.Id, out var statusEntry))
                {
                    messages.Add($"{item.Id}: status missing.");
                    continue;
                }

                var technique = statusEntry.Technique;
                var status = statusEntry.Status;
                if (SQLAuditor.Lib.SkippedEvaluation.IsSkippedOutcome(status)
                    || SQLAuditor.Lib.NotApplicableEvidence.IsNotApplicableOutcome(status))
                {
                    continue;
                }

                var isDecided = string.Equals(status, "Passed", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(status, "Failed", StringComparison.OrdinalIgnoreCase)
                    || string.Equals(status, "Not Applicable", StringComparison.OrdinalIgnoreCase);

                if (string.Equals(technique, "AI-Manual", StringComparison.OrdinalIgnoreCase)
                    && !_copiedManualIds.Contains(item.Id)
                    // A manual item the engine already decided (e.g. a result copied from a previous
                    // run) carries a stored outcome, so it must not be reported as unanswered.
                    && !isDecided)
                {
                    ManualEvaluationState? manualState = null;
                    if (_manualStateMap == null || !_manualStateMap.TryGetValue(item.Id, out manualState) || manualState == null)
                    {
                        messages.Add($"{item.Id}: manual guidance generated but no saved response yet.");
                        continue;
                    }

                    if (!SQLAuditor.Lib.ManualVerdict.IsDecided(manualState.SelectedOutcome))
                    {
                        messages.Add($"{item.Id}: enter Pass, Fail or Not Applicable with the reason and submit.");
                        continue;
                    }

                    if (!manualState.IsSubmitted)
                    {
                        messages.Add($"{item.Id}: manual evaluation not submitted.");
                        continue;
                    }

                    if (!isDecided)
                    {
                        messages.Add($"{item.Id}: current status is '{status}'.");
                    }

                    continue;
                }

                if (!string.Equals(status, "Passed", StringComparison.OrdinalIgnoreCase)
                    && !string.Equals(status, "Failed", StringComparison.OrdinalIgnoreCase))
                {
                    messages.Add($"{item.Id}: current status is '{status}'.");
                }
            }

            return messages;
        }

        private void ManualOutputBox_TextChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
        {
            SaveCurrentManualDraft(true);
        }

        private void AdvanceManualIndex()
        {
            if (_manualQueue == null) return;
            if (_manualIndex < 0) return;
            _manualIndex++;
            if (_manualIndex >= _manualQueue.Count)
            {
                // finished manual queue
                _manualIndex = -1;
                ManualTitle.Text = "Manual steps";
                ManualStepsText.Text = string.Empty;
                ManualOutputBox.Text = string.Empty;
            }
            else
            {
                ShowManualAtIndex();
            }
        }

        private async void RunScanBtn_Click(object sender, RoutedEventArgs e)
        {
            var fqdn = FqdnText.Text.Trim();
            if (string.IsNullOrEmpty(fqdn)) { Log("Enter FQDN first."); return; }
            await EnsureAuditor(fqdn);
            Log("Attempting to run PowerShell scan (if present)...");
            try
            {
                // find script path in caller repo
                var scriptsDir = System.IO.Path.Combine(System.IO.Directory.GetCurrentDirectory(), "SQL", "scripts");
                var psPath = System.IO.Path.Combine(scriptsDir, "07-sql-code-scan.ps1");
                if (!System.IO.File.Exists(psPath)) { Log("PowerShell scan not found."); return; }
                var outText = await _auditor!.RunScriptFileAsync(psPath);
                Log("PowerShell scan complete — output saved to results/.");
            }
            catch (Exception ex)
            {
                Log("Error: " + ex.Message);
            }
        }

        private void ExportBtn_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                var defaultPath = UiFilePath(SqlAuditor.Reporting.ReportSuiteGenerator.AuditReportFileName);
                if (!System.IO.File.Exists(defaultPath))
                {
                    MessageBox.Show($"No final report found at {defaultPath}. Run evaluation first.", "Export", MessageBoxButton.OK, MessageBoxImage.Warning);
                    return;
                }
                var dlg = new SaveFileDialog() { FileName = SqlAuditor.Reporting.ReportSuiteGenerator.AuditReportFileName, Filter = "Markdown|*.md|All Files|*.*" };
                if (dlg.ShowDialog() == true)
                {
                    System.IO.File.Copy(defaultPath, dlg.FileName, true);
                    MessageBox.Show("Exported to " + dlg.FileName, "Export", MessageBoxButton.OK, MessageBoxImage.Information);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show("Export failed: " + ex.Message, "Export", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private bool HasActiveOperationInProgress()
        {
            return _isEvaluating;
        }

        private void ResetChecklistSessionStateForExit()
        {
            _checklistLoaded = false;
            _loadedItems = null;
            _loadedStructure = null;
            _itemTypeMap = null;
            _itemScriptMap = null;
            _selectedIds = null;
            _evalItemMap = null;
            _evalStatusMap = null;
            _manualQueue = null;
            _manualInstructions = null;
            _manualStateMap = null;
            _manualIndex = -1;
            _copiedManualIds.Clear();
            _historicalManualIds.Clear();
            ChecklistTree.Items.Clear();
            MappingTree.Items.Clear();
            Log("Checklist state refreshed on exit.");
        }

        private void HandleExitNavigation()
        {
            if (HasActiveOperationInProgress())
            {
                var currentPage = MainTabs.SelectedIndex == 0 ? "Login" : MainTabs.SelectedIndex == 1 ? "Checklist" : MainTabs.SelectedIndex == 2 ? "Evaluate" : "Summary";
                var result = MessageBox.Show(
                    $"A {currentPage} operation is still in progress. Do you want to cancel it and exit?",
                    "Exit with active operation",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Warning);

                if (result != MessageBoxResult.Yes)
                {
                    return;
                }
            }

            CancelActiveEvaluationIfNeeded();

            if (MainTabs.SelectedIndex == 1)
            {
                ResetChecklistSessionStateForExit();
            }

            var destination = MainTabs.SelectedIndex == 1 || _viewingPreviousEvaluation ? 0 : 1;
            _viewingPreviousEvaluation = false;
            SetTabIndex(destination);
            UpdateStageIndicators();
        }

        private void ExitHeaderBtn_Click(object sender, RoutedEventArgs e)
        {
            HandleExitNavigation();
        }

        // Opens the Evaluations History window (available on any tab, before any details are filled).
        private void EvaluationHistoryBtn_Click(object sender, RoutedEventArgs e)
        {
            if (_isEvaluating)
            {
                MessageBox.Show(this, "An evaluation is currently running. Wait for it to finish before opening the history.", "Evaluation in progress", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            var window = new EvaluationsHistoryWindow { Owner = this };
            var result = window.ShowDialog();
            if (result != true || window.SelectedRun == null || window.Action == HistoryAction.None) return;

            BeginResumeFromHistory(window.SelectedRun, window.Action == HistoryAction.Edit);
        }

        // Prefills the Login page from a stored run and prepares to rerun or edit it in-place. The
        // SQL password and LLM API key are never stored, so the user re-enters them here.
        private void BeginResumeFromHistory(SQLAuditor.Lib.PreviousEvaluation run, bool editMode)
        {
            var meta = run.Metadata;
            _resumeRunDirectory = run.RunDirectory;
            _resumeIsEdit = editMode;
            _resumeFqdn = meta.Fqdn;
            _resumeDatabases = meta.Databases?.ToList();
            _resumeSelectedItemIds = meta.SelectedItemIds?.ToList();

            var isSqlAuth = string.Equals(meta.AuthMethod, "SQL Login", StringComparison.OrdinalIgnoreCase)
                || string.Equals(meta.AuthMethod, "SQL", StringComparison.OrdinalIgnoreCase);

            if (!string.IsNullOrWhiteSpace(meta.Fqdn)) FqdnText.Text = meta.Fqdn;
            SelectAuthMethod(isSqlAuth);
            SqlUserBox.Text = isSqlAuth ? (meta.SqlUser ?? string.Empty) : string.Empty;
            SqlPassBox.Password = string.Empty;
            if (!string.IsNullOrWhiteSpace(meta.LlmBaseUrl)) LlmBaseUrlText.Text = meta.LlmBaseUrl;
            if (!string.IsNullOrWhiteSpace(meta.LlmModel)) LlmModelText.Text = meta.LlmModel;
            LlmApiKeyBox.Password = string.Empty;

            InvalidateSqlVerification();
            SetTabIndex(0);
            UpdateStageIndicators();
            // Rerun and Edit reuse the previous run's server, so the server inputs are locked.
            SetServerInputsLocked(true);

            var mode = editMode ? "Edit" : "Rerun";
            Log($"{mode} mode: reusing run {System.IO.Path.GetFileName(run.RunDirectory)} for {meta.ServerName}. Reports will overwrite the original folder.");
            MessageBox.Show(this,
                $"{mode} prepared for server '{meta.ServerName}'.\n\n"
                + "1. Re-enter the SQL password (if using SQL Login) and click Verify Access.\n"
                + (editMode
                    ? "2. Adjust the database, LLM details, or manual CSV as needed.\n"
                    : "2. The stored databases and checklist items are preselected.\n")
                + "3. Continue to the checklist and start the evaluation.\n\n"
                + "The reports will be regenerated in the original run folder.",
                mode + " evaluation",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }

        private void SelectAuthMethod(bool sqlLogin) => AuthMethodCombo.SelectedIndex = sqlLogin ? 1 : 0;

        // The SQL password stays editable (it is never stored and must be re-entered for SQL auth).
        private void SetServerInputsLocked(bool locked)
        {
            FqdnText.IsEnabled = !locked;
            AuthMethodCombo.IsEnabled = !locked;
            SqlUserBox.IsEnabled = !locked;

            // A rerun/edit targets one historical run folder, so a fleet run is not available
            // while it is armed.
            if (locked && MultiServerToggle.IsChecked == true)
            {
                _suppressMultiServerToggle = true;
                MultiServerToggle.IsChecked = false;
                _suppressMultiServerToggle = false;
                _servers.Clear();
                ServerListSection.Visibility = Visibility.Collapsed;
                ServersRow.Height = GridLength.Auto;
                Log("Multi-server mode turned off: rerun/edit applies to the single server of the stored run.");
            }
            MultiServerToggle.IsEnabled = !locked;
        }

        // Captures the UI-supplied inputs recorded with a run so it can be rerun or edited later.
        private SQLAuditor.Lib.RunInputs BuildRunInputs()
        {
            var isSqlAuth = string.Equals(
                (AuthMethodCombo.SelectedItem as System.Windows.Controls.ComboBoxItem)?.Content?.ToString(),
                "SQL Login", StringComparison.OrdinalIgnoreCase);
            return new SQLAuditor.Lib.RunInputs
            {
                Fqdn = string.IsNullOrWhiteSpace(FqdnText.Text) ? null : FqdnText.Text.Trim(),
                AuthMethod = isSqlAuth ? "SQL Login" : "Windows Authentication",
                SqlUser = isSqlAuth && !string.IsNullOrWhiteSpace(SqlUserBox.Text) ? SqlUserBox.Text.Trim() : null,
                LlmBaseUrl = string.IsNullOrWhiteSpace(LlmBaseUrlText.Text) ? null : LlmBaseUrlText.Text.Trim(),
                LlmModel = string.IsNullOrWhiteSpace(LlmModelText.Text) ? null : LlmModelText.Text.Trim(),
            };
        }

        private void ApplyResumeDatabaseSelection()
        {
            if (_resumeDatabases == null || _resumeDatabases.Count == 0) return;
            var wanted = new System.Collections.Generic.HashSet<string>(_resumeDatabases, StringComparer.OrdinalIgnoreCase);
            var matched = 0;
            foreach (var option in _databaseOptionCheckBoxes)
            {
                if (option.Tag is string name && wanted.Contains(name))
                {
                    option.IsChecked = true;
                    matched++;
                }
            }
            if (matched > 0) Log($"Preselected {matched} database(s) from the previous run.");

            // Rerun and Edit both reuse the databases from the previous run, so the selection is locked.
            if (matched > 0 && _resumeRunDirectory != null)
            {
                DatabaseSelectorToggle.IsChecked = false;
                DatabaseSelectorToggle.IsEnabled = false;
                Log("Database selection is locked to the previous run's databases.");
            }
        }

        // On rerun the checklist is fixed to the previous run's items; Edit still allows changes.
        private void ApplyChecklistLockForResume()
        {
            if (_resumeRunDirectory == null || _resumeIsEdit) return;

            foreach (var areaObj in ChecklistTree.Items)
            {
                if (areaObj is System.Windows.Controls.TreeViewItem areaNode
                    && areaNode.Header is System.Windows.Controls.StackPanel sp)
                {
                    foreach (var child in sp.Children)
                        if (child is System.Windows.Controls.CheckBox areaCb) areaCb.IsEnabled = false;
                }
            }
            foreach (var cb in EnumerateChecklistItemCheckBoxes())
                cb.IsEnabled = false;
            if (SelectAllChecklistCb != null) SelectAllChecklistCb.IsEnabled = false;

            Log("Checklist is locked for this rerun (using the previous run's items). Use Edit to change the selection.");
        }

        private void ApplyResumeChecklistSelection()
        {
            if (_resumeSelectedItemIds == null || _resumeSelectedItemIds.Count == 0) return;
            var wanted = new System.Collections.Generic.HashSet<string>(_resumeSelectedItemIds, StringComparer.OrdinalIgnoreCase);
            var matched = 0;
            foreach (var cb in EnumerateChecklistItemCheckBoxes())
            {
                if (cb.Tag is SQLAuditor.Lib.ChecklistItem item)
                {
                    var shouldCheck = wanted.Contains(item.Id);
                    cb.IsChecked = shouldCheck;
                    if (shouldCheck) matched++;
                }
            }
            SyncSelectAllState();
            if (matched > 0) Log($"Preselected {matched} checklist item(s) from the previous run. Adjust the selection if needed.");
        }

        private void ClearResumeState()
        {
            _resumeRunDirectory = null;
            _resumeIsEdit = false;
            _resumeFqdn = null;
            _resumeDatabases = null;
            _resumeSelectedItemIds = null;
            SetServerInputsLocked(false);
        }

        private void ExitSummaryBtn_Click(object sender, RoutedEventArgs e)
        {
            HandleExitNavigation();
        }

        private SqlAuthMethod SelectedAuthMethod =>
            (AuthMethodCombo.SelectedItem as System.Windows.Controls.ComboBoxItem)?.Tag is SqlAuthMethod m
                ? m
                : SqlAuthMethod.WindowsIntegrated;

        // Shows only the credential fields the selected method actually uses.
        private void ApplyAuthMode()
        {
            var method = SelectedAuthMethod;
            var isEntra = SqlAuthProfile.IsEntraMethod(method);

            var showUser = method != SqlAuthMethod.WindowsIntegrated;
            var showSecret = method is SqlAuthMethod.SqlLogin or SqlAuthMethod.EntraServicePrincipal;

            AuthUserPanel.Visibility = showUser ? Visibility.Visible : Visibility.Collapsed;
            AuthSecretPanel.Visibility = showSecret ? Visibility.Visible : Visibility.Collapsed;
            AuthTenantPanel.Visibility = isEntra ? Visibility.Visible : Visibility.Collapsed;

            AuthUserLabel.Text = SqlAuthProfile.UserIdLabelFor(method);
            AuthSecretLabel.Text = SqlAuthProfile.SecretLabelFor(method);

            if (!showUser) SqlUserBox.Text = string.Empty;
            if (!showSecret) SqlPassBox.Password = string.Empty;
            if (!isEntra) TenantIdBox.Text = string.Empty;

            // Handing an Entra token to an unverified server defeats the point of the token.
            EncryptCheck.IsChecked = true;
            TrustServerCertCheck.IsChecked = !isEntra;

            var hint = method switch
            {
                SqlAuthMethod.EntraInteractive => "A browser window will open for sign-in, including MFA.",
                SqlAuthMethod.EntraManagedIdentity => "Uses the managed identity of the machine this app runs on.",
                _ => string.Empty,
            };
            AuthHintText.Text = hint;
            AuthHintText.Visibility = string.IsNullOrEmpty(hint) ? Visibility.Collapsed : Visibility.Visible;
        }

        private SqlAuthProfile BuildAuthProfile(string fqdn) => new()
        {
            Method = SelectedAuthMethod,
            Server = fqdn,
            Database = "master",
            UserId = AuthUserPanel.Visibility == Visibility.Visible ? SqlUserBox.Text?.Trim() : null,
            Secret = AuthSecretPanel.Visibility == Visibility.Visible ? SqlPassBox.Password : null,
            TenantId = AuthTenantPanel.Visibility == Visibility.Visible ? TenantIdBox.Text?.Trim() : null,
            Encrypt = EncryptCheck.IsChecked == true,
            TrustServerCertificate = TrustServerCertCheck.IsChecked == true,
        };

        private async Task EnsureAuditor(string fqdn)
        {
            if (_auditor != null) return;

            var profile = BuildAuthProfile(fqdn);
            var validationError = profile.Validate();
            if (validationError != null) throw new InvalidOperationException(validationError);

            _auditor = new Auditor(profile);
            Log($"Connecting to {fqdn} using {profile.Describe()}.");
            // Attempt to normalize the connection (try common server variants) so UI verification and later runs use a working connection string
            try
            {
                await _auditor.TestAndNormalizeConnectionAsync();
            }
            catch { }
            await Task.CompletedTask;
        }

        private void MainTabs_PreviewMouseDown(object sender, System.Windows.Input.MouseButtonEventArgs e)
        {
            // Prevent users from switching tabs by clicking on headers. Only allow programmatic navigation.
            if (_allowTabChange) return;
            try
            {
                var src = e.OriginalSource as System.Windows.DependencyObject;
                while (src != null && !(src is System.Windows.Controls.TabItem))
                {
                    src = System.Windows.Media.VisualTreeHelper.GetParent(src);
                }
                if (src is System.Windows.Controls.TabItem)
                {
                    e.Handled = true; // swallow header click
                }
            }
            catch { e.Handled = true; }
        }

        private void SetTabIndex(int idx)
        {
            try
            {
                _allowTabChange = true;
                MainTabs.SelectedIndex = idx;
            }
            finally { _allowTabChange = false; }
        }

        private void CancelActiveEvaluationIfNeeded()
        {
            if (_pendingUserInput != null && !_pendingUserInput.Task.IsCompleted)
            {
                try { _pendingUserInput.TrySetCanceled(); } catch { }
            }

            if (_evaluationCts != null && !_evaluationCts.IsCancellationRequested)
            {
                try { _evaluationCts.Cancel(); } catch { }
            }

            _isEvaluating = false;
            Log("Evaluation cancelled by exit request.");
        }

        private void InvalidateSqlVerification()
        {
            var hadConnectionState = _isVerified || _isVerifyingSql || _auditor != null;
            _sqlConnectionInputsVersion++;
            _isVerified = false;
            _auditor = null;
            ResetDatabaseSelection();
            // Pointing at a different server ends any rerun/edit resume so a fresh run folder is used.
            if (_resumeRunDirectory != null && _resumeFqdn != null
                && !string.Equals(FqdnText.Text?.Trim(), _resumeFqdn, StringComparison.OrdinalIgnoreCase))
            {
                ClearResumeState();
                Log("Server changed \u2014 rerun/edit link cleared; a new run folder will be created.");
            }
            if (hadConnectionState)
                AccessStatus.Text = "Connection details changed. Verify access again.";
            UpdateStageIndicators();
        }

        private void ResetDatabaseSelection()
        {
            _suppressDatabaseSelectionSync = true;
            try
            {
                DatabaseSelectorToggle.IsChecked = false;
                DatabaseSelectorToggle.IsEnabled = false;
                DatabaseSelectorPanel.Visibility = Visibility.Collapsed;
                DatabaseSelectionText.Text = "Select Databases";
                DatabaseSelectionText.ToolTip = null;
                DatabaseOptionsPanel.Children.Clear();
                _databaseOptionCheckBoxes.Clear();
                _allDatabasesCheckBox = null;
            }
            finally
            {
                _suppressDatabaseSelectionSync = false;
            }
            UpdateStartEvaluationEnabled();
        }

        private void PopulateDatabaseSelection(System.Collections.Generic.IEnumerable<string> databaseNames)
        {
            var names = databaseNames
                .Where(name => !string.IsNullOrWhiteSpace(name))
                .Select(name => name.Trim())
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(name => name, StringComparer.OrdinalIgnoreCase)
                .ToArray();

            _suppressDatabaseSelectionSync = true;
            try
            {
                DatabaseOptionsPanel.Children.Clear();
                _databaseOptionCheckBoxes.Clear();

                _allDatabasesCheckBox = CreateDatabaseOption("All Databases", null, true);
                DatabaseOptionsPanel.Children.Add(_allDatabasesCheckBox);

                foreach (var name in names)
                {
                    var option = CreateDatabaseOption(name, name, false);
                    _databaseOptionCheckBoxes.Add(option);
                    DatabaseOptionsPanel.Children.Add(option);
                }

                DatabaseSelectorToggle.IsChecked = false;
                DatabaseSelectorToggle.IsEnabled = names.Length > 0;
                DatabaseSelectorPanel.Visibility = Visibility.Visible;
                DatabaseSelectionText.Text = "Select Databases";
                DatabaseSelectionText.ToolTip = null;
            }
            finally
            {
                _suppressDatabaseSelectionSync = false;
            }
            UpdateDatabaseSelectionSummary();
        }

        private System.Windows.Controls.CheckBox CreateDatabaseOption(
            string label,
            string? databaseName,
            bool isAllDatabases)
        {
            var option = new System.Windows.Controls.CheckBox
            {
                Content = label,
                Tag = databaseName,
                Padding = new Thickness(6, 5, 6, 5),
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                FontWeight = isAllDatabases ? FontWeights.SemiBold : FontWeights.Normal
            };
            option.Checked += DatabaseOption_Changed;
            option.Unchecked += DatabaseOption_Changed;
            return option;
        }

        private void DatabaseOption_Changed(object sender, RoutedEventArgs e)
        {
            if (_suppressDatabaseSelectionSync) return;

            _suppressDatabaseSelectionSync = true;
            try
            {
                if (ReferenceEquals(sender, _allDatabasesCheckBox))
                {
                    var selectAll = _allDatabasesCheckBox?.IsChecked == true;
                    foreach (var option in _databaseOptionCheckBoxes)
                        option.IsChecked = selectAll;
                }
                else if (_allDatabasesCheckBox != null)
                {
                    _allDatabasesCheckBox.IsChecked =
                        _databaseOptionCheckBoxes.Count > 0 &&
                        _databaseOptionCheckBoxes.All(option => option.IsChecked == true);
                }
            }
            finally
            {
                _suppressDatabaseSelectionSync = false;
            }

            UpdateDatabaseSelectionSummary();
        }

        private string[] GetSelectedDatabaseNames()
        {
            return _databaseOptionCheckBoxes
                .Where(option => option.IsChecked == true && option.Tag is string)
                .Select(option => (string)option.Tag)
                .ToArray();
        }

        // ---- Evidence sources: repositories, pipelines and documents attached to the run ----

        private void AddEvidenceFolderBtn_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new Microsoft.Win32.OpenFolderDialog
            {
                Title = "Select an evidence folder (a cloned repository, or a documentation folder)",
                Multiselect = true,
            };
            if (dialog.ShowDialog(this) != true) return;

            foreach (var folder in dialog.FolderNames)
            {
                if (!_evidenceFolders.Contains(folder, StringComparer.OrdinalIgnoreCase))
                    _evidenceFolders.Add(folder);
            }
            _evidenceContext = null;
            UpdateEvidenceSummary();
        }

        private void AddEvidenceFileBtn_Click(object sender, RoutedEventArgs e)
        {
            var dialog = new Microsoft.Win32.OpenFileDialog
            {
                Title = "Select evidence file(s) (a pipeline definition, a runbook, a policy document)",
                Multiselect = true,
            };
            if (dialog.ShowDialog(this) != true) return;

            foreach (var file in dialog.FileNames)
            {
                if (!_evidenceFiles.Contains(file, StringComparer.OrdinalIgnoreCase))
                    _evidenceFiles.Add(file);
            }
            _evidenceContext = null;
            UpdateEvidenceSummary();
        }

        private void ClearEvidenceBtn_Click(object sender, RoutedEventArgs e)
        {
            _evidenceFolders.Clear();
            _evidenceFiles.Clear();
            _evidenceContext = null;
            EvidenceGitUrlBox.Text = string.Empty;
            EvidenceGitRefBox.Text = string.Empty;
            UpdateEvidenceSummary();
        }

        private void ToggleEvidenceBtn_Click(object sender, RoutedEventArgs e)
        {
            var show = EvidencePanel.Visibility != Visibility.Visible;
            EvidencePanel.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
            ToggleEvidenceBtn.Content = show ? "Hide Evidence" : "Attach Evidence (optional)";
            if (show) UpdateEvidenceSummary();
        }

        private void EvidenceInput_Changed(object sender, System.Windows.Controls.TextChangedEventArgs e)
        {
            // A changed URL invalidates the previously indexed workspace.
            _evidenceContext = null;
            UpdateEvidenceSummary();
        }

        private async void IndexEvidenceBtn_Click(object sender, RoutedEventArgs e)
        {
            var gitUrl = (EvidenceGitUrlBox.Text ?? string.Empty).Trim();
            if (_evidenceFolders.Count == 0 && _evidenceFiles.Count == 0 && gitUrl.Length == 0)
            {
                MessageBox.Show(this, "Add a folder, a file or a Git repository URL before indexing.", "Evidence", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }

            await IndexEvidenceAsync(showSummaryDialog: true);
        }

        /// <summary>
        /// A permanent provider fault (expired key, wrong model) silently disables every AI-backed
        /// step, so it has to be said out loud rather than left in the diagnostics log.
        /// </summary>
        private void ReportProviderFault()
        {
            var fault = SQLAuditor.Lib.Auditor.ProviderFault;
            if (string.IsNullOrWhiteSpace(fault)) return;

            Log("AI provider unavailable for this run: " + fault);
            MessageBox.Show(this,
                "The AI provider rejected this run, so evidence review and AI wording were disabled and "
                + "every documentation item was left for manual review.\n\n"
                + fault
                + "\n\nFix the provider configuration (commonly an expired or invalid API key) and run the evaluation again.",
                "AI provider unavailable", MessageBoxButton.OK, MessageBoxImage.Warning);
        }

        /// <summary>
        /// Indexes evidence the user supplied but never indexed by hand. Without this, typing a Git
        /// URL and pressing Evaluate silently ran the audit with no evidence at all.
        /// </summary>
        private async Task EnsureEvidenceIndexedAsync()
        {
            if (_evidenceContext != null) return;

            var gitUrl = (EvidenceGitUrlBox.Text ?? string.Empty).Trim();
            if (_evidenceFolders.Count == 0 && _evidenceFiles.Count == 0 && gitUrl.Length == 0) return;

            Log("Evidence was supplied but not indexed; indexing it now before the evaluation starts.");
            await IndexEvidenceAsync(showSummaryDialog: false);

            if (_evidenceContext is not { HasUsableEvidence: true })
            {
                MessageBox.Show(this,
                    "The evidence you supplied could not be read, so the documentation items will be left for manual review.\n\n"
                    + "Check the Evidence panel for the reason, fix it, and re-run if you want those items decided from the evidence.",
                    "Evidence", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        }

        private async Task IndexEvidenceAsync(bool showSummaryDialog)
        {
            var gitUrl = (EvidenceGitUrlBox.Text ?? string.Empty).Trim();

            if (gitUrl.Length > 0)
            {
                // Pasting the branch page from a browser is the common mistake; name the clone URL
                // and the branch to enter rather than letting git fail later.
                if (SQLAuditor.Lib.EvidenceRepositoryUrl.TryParseBrowseUrl(gitUrl) is { } browse)
                {
                    MessageBox.Show(this,
                        SQLAuditor.Lib.EvidenceRepositoryUrl.DescribeBrowseUrlRejection(browse),
                        "Evidence", MessageBoxButton.OK, MessageBoxImage.Warning);
                    return;
                }

                if (!SQLAuditor.Lib.EvidenceWorkspace.IsSupportedRemoteUrl(gitUrl))
                {
                    MessageBox.Show(this,
                        "Only https:// Git clone URLs are supported. SSH remotes and file:// paths are rejected.\n\n"
                        + "For a private repository, set SQLAUDITOR_GIT_TOKEN in the environment before launching this app — never paste a token into the URL.",
                        "Evidence", MessageBoxButton.OK, MessageBoxImage.Warning);
                    return;
                }
            }

            IndexEvidenceBtn.IsEnabled = false;
            EvidenceSummaryText.Text = "Resolving and indexing evidence...";
            try
            {
                _evidenceContext = await SQLAuditor.Lib.EvidenceStore.AttachAsync(
                    _evidenceFolders, gitUrl.Length == 0 ? null : gitUrl,
                    (EvidenceGitRefBox.Text ?? string.Empty).Trim(), _evidenceFiles,
                    persist: false);

                UpdateEvidenceSummary();
                Log($"Evidence indexed: {_evidenceContext.Manifest.Files.Count} file(s) across {_evidenceContext.Sources.Count(s => s.IsResolved)} source(s).");
                foreach (var failed in _evidenceContext.Sources.Where(s => !s.IsResolved))
                    Log($"Evidence source could not be read: {failed.Location} — {failed.Error}");

                if (showSummaryDialog) ShowEvidenceSummaryDialog(_evidenceContext);
            }
            catch (Exception ex)
            {
                _evidenceContext = null;
                EvidenceSummaryText.Text = "Indexing failed.";
                Log("Failed to index evidence: " + ex.Message);
                MessageBox.Show(this, "Could not index the evidence:\n\n" + ex.Message, "Evidence", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            finally
            {
                IndexEvidenceBtn.IsEnabled = true;
            }
        }

        private void ShowEvidenceSummaryDialog(SQLAuditor.Lib.EvidenceContext context)
        {
            var resolved = context.Sources.Count(s => s.IsResolved);
            var failed = context.Sources.Count(s => !s.IsResolved);

            var headline = context.HasUsableEvidence
                ? $"{context.Manifest.Files.Count} file(s) indexed from {resolved} source(s)"
                : "No evidence was indexed";
            var subhead = context.HasUsableEvidence
                ? "Documentation and process checklist items will be decided from these artefacts. Anything they cannot settle is still queued for manual review."
                : "Nothing could be read, so every documentation item will be queued for manual review.";
            if (failed > 0)
                subhead += $" {failed} source(s) could not be resolved — see the detail below.";

            new EvidenceSummaryWindow(headline, subhead, SQLAuditor.Lib.EvidenceStore.Describe(context)) { Owner = this }
                .ShowDialog();
        }

        // The card only carries a one-line status; the full manifest lives in the modal above.
        private void UpdateEvidenceSummary()
        {
            if (EvidenceSummaryText == null) return;

            if (_evidenceContext != null)
            {
                var resolved = _evidenceContext.Sources.Count(s => s.IsResolved);
                EvidenceSummaryText.Text = _evidenceContext.HasUsableEvidence
                    ? $"Indexed: {_evidenceContext.Manifest.Files.Count} file(s) from {resolved} source(s)."
                    : "Indexed, but no readable files were found.";
                return;
            }

            var pending = _evidenceFolders.Count + _evidenceFiles.Count
                + ((EvidenceGitUrlBox?.Text ?? string.Empty).Trim().Length > 0 ? 1 : 0);
            EvidenceSummaryText.Text = pending == 0
                ? "No evidence attached."
                : $"{pending} source(s) selected — click Validate / Index Evidence.";
        }

        private void UpdateDatabaseSelectionSummary()
        {
            var selected = GetSelectedDatabaseNames();
            DatabaseSelectionText.Text = selected.Length switch
            {
                0 => "Select Databases",
                1 => selected[0],
                _ when selected.Length == _databaseOptionCheckBoxes.Count => "All Databases",
                _ => $"{selected.Length} databases selected"
            };
            DatabaseSelectionText.ToolTip = selected.Length == 0
                ? null
                : string.Join(Environment.NewLine, selected);
            UpdateStartEvaluationEnabled();
        }

        private async void VerifyBtn_Click(object sender, RoutedEventArgs e)
        {
            var fqdn = FqdnText.Text.Trim();
            if (string.IsNullOrEmpty(fqdn)) { AccessStatus.Text = "Enter FQDN first."; return; }
            _isVerified = false;
            _auditor = null;
            ResetDatabaseSelection();
            var verificationVersion = _sqlConnectionInputsVersion;
            _isVerifyingSql = true;
            AccessStatus.Text = SelectedAuthMethod == SqlAuthMethod.EntraInteractive
                ? "Testing connection... complete the sign-in in the browser window."
                : "Testing connection...";
            VerifyBtn.IsEnabled = false;
            try
            {
                await EnsureAuditor(fqdn);
                if (verificationVersion != _sqlConnectionInputsVersion || _auditor == null)
                {
                    Log("Discarded SQL verification because the connection details changed.");
                    return;
                }
                var candidateAuditor = _auditor;
                var ok = await candidateAuditor.TestConnectionAsync();
                if (verificationVersion != _sqlConnectionInputsVersion)
                {
                    Log("Discarded SQL verification because the connection details changed.");
                    return;
                }
                if (ok)
                {
                    var databases = await candidateAuditor.GetAvailableDatabasesAsync();
                    if (verificationVersion != _sqlConnectionInputsVersion)
                    {
                        Log("Discarded database discovery because the connection details changed.");
                        return;
                    }
                    _auditor = candidateAuditor;
                    _isVerified = true;
                    PopulateDatabaseSelection(databases);
                    ApplyResumeDatabaseSelection();
                    AccessStatus.Text = databases.Length == 0
                        ? $"Verified: {fqdn}. No accessible user databases found."
                        : $"Verified: {fqdn}. {databases.Length} database(s) available.";
                    Log($"Connection to {fqdn} verified; {databases.Length} user database(s) available.");
                }
                else
                {
                    _isVerified = false;
                    AccessStatus.Text = "Failed to connect.";
                    Log($"Failed to connect to {fqdn}.");
                }
            }
            catch (InvalidOperationException ex)
            {
                _isVerified = false;
                AccessStatus.Text = ex.Message;
                Log("Verify error: " + ex.Message);
            }
            catch (Exception ex)
            {
                _isVerified = false;
                AccessStatus.Text = "Error testing connection.";
                Log("Verify error: " + ex.Message);
            }
            finally
            {
                _isVerifyingSql = false;
                VerifyBtn.IsEnabled = true;
                UpdateStartEvaluationEnabled();
                UpdateStageIndicators();
            }
        }

        // Verifies ONLY the LLM provider connection. Does not navigate.
        private async void VerifyLlmBtn_Click(object sender, RoutedEventArgs e)
        {
            var baseUrl = LlmBaseUrlText.Text.Trim();
            var apiKey = LlmApiKeyBox.Password ?? string.Empty;
            var model = LlmModelText.Text.Trim();
            if (string.IsNullOrWhiteSpace(baseUrl) || string.IsNullOrWhiteSpace(apiKey) || string.IsNullOrWhiteSpace(model))
            {
                LlmAccessStatus.Text = "Enter Base URL, API Key, and Model.";
                _isLlmVerified = false;
                UpdateStartEvaluationEnabled();
                return;
            }

            LlmAccessStatus.Text = "Verifying LLM access...";
            VerifyLlmBtn.IsEnabled = false;
            try
            {
                // Runtime-only configuration; never written to disk.
                Auditor.SetLlmConfig(baseUrl, apiKey, model);
                var (ok, message) = await Auditor.VerifyLlmAsync();
                if (ok)
                {
                    _isLlmVerified = true;
                    LlmAccessStatus.Text = "Verified: " + message;
                    _auditor?.EnsureLlmEvaluators();
                    Log("LLM provider verified (" + model + ").");
                }
                else
                {
                    _isLlmVerified = false;
                    LlmAccessStatus.Text = "Failed: " + message;
                    Log("LLM verification failed: " + message);
                }
            }
            catch (Exception ex)
            {
                _isLlmVerified = false;
                LlmAccessStatus.Text = "Error: " + ex.Message;
                Log("LLM verify error: " + ex.Message);
            }
            finally
            {
                VerifyLlmBtn.IsEnabled = true;
                UpdateStartEvaluationEnabled();
            }
        }

        // The ONLY control that navigates from Login to the Checklist page.
        private async void StartEvaluationBtn_Click(object sender, RoutedEventArgs e)
        {
            var targetDatabases = GetSelectedDatabaseNames();
            if (!_isVerified || targetDatabases.Length == 0) return;

            _viewingPreviousEvaluation = false;

            // Make sure the LLM evaluators reflect the verified runtime configuration.
            _auditor?.EnsureLlmEvaluators();

            SetTabIndex(1);
            LoadChecklistBtn.IsEnabled = true;
            Log($"Proceeding to checklist with {targetDatabases.Length} database target(s).");
            try
            {
                await PopulateChecklistStructureAsync();
                ApplyResumeChecklistSelection();
                ApplyChecklistLockForResume();
                Log("Checklist auto-loaded.");
            }
            catch (Exception ex)
            {
                Log("Failed to auto-load checklist: " + ex.Message);
            }
            UpdateStageIndicators();
        }

        private void UpdateStartEvaluationEnabled()
        {
            var ready = _isVerified && GetSelectedDatabaseNames().Length > 0;

            if (StartEvaluationBtn != null)
            {
                StartEvaluationBtn.IsEnabled = ready;
                StartEvaluationBtn.Content = "Continue to Checklist";
            }

            if (AddCustomChecklistItemBtn != null)
            {
                // Rerun forbids adding checklist items; Edit still allows custom items.
                var rerunLock = _resumeRunDirectory != null && !_resumeIsEdit;
                AddCustomChecklistItemBtn.IsEnabled = ready && _isLlmVerified && !rerunLock;
            }
        }

        private sealed class CustomChecklistCardItem
        {
            public string Id { get; init; } = "";
            public string Title { get; init; } = "";
            public string SubAreaLabel { get; init; } = "";
        }

        private void RefreshCustomChecklistCard()
        {
            try
            {
                var items = SQLAuditor.Lib.ChecklistConfigurationStore.GetCatalog()
                    .Where(item => item.IsCustom)
                    .OrderBy(item => item.Id, System.Collections.Generic.Comparer<string>.Create(
                        SQLAuditor.Lib.ChecklistConfigurationStore.CompareIds))
                    .Select(item => new CustomChecklistCardItem
                    {
                        Id = item.Id,
                        Title = string.IsNullOrWhiteSpace(item.Title) ? item.Text : item.Title,
                        SubAreaLabel = string.IsNullOrWhiteSpace(item.SubAreaTitle)
                            ? item.SubAreaId
                            : $"{item.SubAreaId} - {item.SubAreaTitle}"
                    })
                    .ToList();

                CustomChecklistItems.ItemsSource = items;

                var hasItems = items.Count > 0;
                CustomChecklistScroll.Visibility = hasItems ? Visibility.Visible : Visibility.Collapsed;
                CustomChecklistEmptyText.Visibility = hasItems ? Visibility.Collapsed : Visibility.Visible;
                CustomChecklistStatus.Text = hasItems
                    ? $"{items.Count} custom checklist item(s) configured."
                    : string.Empty;
            }
            catch (Exception ex)
            {
                CustomChecklistItems.ItemsSource = null;
                CustomChecklistScroll.Visibility = Visibility.Collapsed;
                CustomChecklistEmptyText.Visibility = Visibility.Visible;
                CustomChecklistStatus.Text = "Could not load custom checklist items: " + ex.Message;
            }
        }

        private async void ConfigureChecklistBtn_Click(object sender, RoutedEventArgs e)
        {
            var editor = new ConfigureChecklistWindow { Owner = this };
            if (editor.ShowDialog() != true || editor.Requests.Count == 0) return;

            Log($"Configuring {editor.Requests.Count} custom checklist item(s)...");

            var progressWindow = new CustomChecklistProgressWindow(editor.Requests) { Owner = this };
            progressWindow.Start();
            progressWindow.ShowDialog();

            var result = progressWindow.Result;
            if (result != null)
            {
                foreach (var outcome in result.Outcomes)
                {
                    Log(outcome.IsAdded
                        ? $"Custom checklist {outcome.AssignedId} added under {outcome.SubAreaId} ({outcome.SubAreaTitle})."
                        : $"Custom checklist '{outcome.Title}' not added - {outcome.Status}: {outcome.Detail}");
                }
            }
            else
            {
                Log("Custom checklist configuration was cancelled.");
            }

            RefreshCustomChecklistCard();

            _auditor?.EnsureLlmEvaluators();
            SetTabIndex(1);
            LoadChecklistBtn.IsEnabled = true;
            try
            {
                await PopulateChecklistStructureAsync();
                Log("Checklist reloaded with the merged default + custom configuration.");
            }
            catch (Exception ex)
            {
                Log("Failed to reload the checklist: " + ex.Message);
            }
            UpdateStageIndicators();
        }

        private void Send_Click(object sender, RoutedEventArgs e)
        {
            Log("Send clicked (legacy) - no input box present.");
        }

        private static string GetChecklistAreaId(string? itemId)
        {
            if (string.IsNullOrWhiteSpace(itemId)) return string.Empty;
            var parts = itemId.Split('.', StringSplitOptions.RemoveEmptyEntries);
            return parts.Length > 0 ? parts[0] : string.Empty;
        }

        private static string GetChecklistSubAreaId(string? itemId)
        {
            if (string.IsNullOrWhiteSpace(itemId)) return string.Empty;
            var parts = itemId.Split('.', StringSplitOptions.RemoveEmptyEntries);
            return parts.Length >= 2 ? string.Join('.', parts.Take(2)) : parts.Length > 0 ? parts[0] : string.Empty;
        }

        private static int CompareChecklistIds(string? left, string? right)
        {
            if (string.IsNullOrWhiteSpace(left) && string.IsNullOrWhiteSpace(right)) return 0;
            if (string.IsNullOrWhiteSpace(left)) return 1;
            if (string.IsNullOrWhiteSpace(right)) return -1;

            var leftParts = left.Split('.', StringSplitOptions.RemoveEmptyEntries).Select(p => int.TryParse(p, out var v) ? v : int.MaxValue).ToArray();
            var rightParts = right.Split('.', StringSplitOptions.RemoveEmptyEntries).Select(p => int.TryParse(p, out var v) ? v : int.MaxValue).ToArray();

            var depth = Math.Max(leftParts.Length, rightParts.Length);
            for (int i = 0; i < depth; i++)
            {
                var leftValue = i < leftParts.Length ? leftParts[i] : int.MaxValue;
                var rightValue = i < rightParts.Length ? rightParts[i] : int.MaxValue;
                if (leftValue != rightValue) return leftValue.CompareTo(rightValue);
            }

            return string.Compare(left, right, StringComparison.OrdinalIgnoreCase);
        }

        private static string FormatAreaLabel(string? areaId, string? title)
        {
            if (string.IsNullOrWhiteSpace(areaId)) return string.IsNullOrWhiteSpace(title) ? "Area" : title;
            return string.IsNullOrWhiteSpace(title) ? $"Area {areaId}" : $"Area {areaId}: {title}";
        }

        private static string FormatSubAreaLabel(string? subAreaId, string? title)
        {
            if (string.IsNullOrWhiteSpace(subAreaId)) return string.IsNullOrWhiteSpace(title) ? "Sub-area" : title;
            return string.IsNullOrWhiteSpace(title) ? $"Sub-area {subAreaId}" : $"Sub-area {subAreaId}: {title}";
        }

        private void AreaCb_Checked(object? sender, RoutedEventArgs e)
        {
            if (sender is System.Windows.Controls.CheckBox cb && cb.Parent is System.Windows.Controls.StackPanel sp)
            {
                // parent TreeViewItem is two levels up
                var tvi = FindAncestor<System.Windows.Controls.TreeViewItem>(sp);
                if (tvi != null)
                {
                    SetChildrenChecked(tvi, true);
                }
            }
        }

        private void SelectAllChecklistCb_Checked(object sender, RoutedEventArgs e) => SetAllChecklistChecked(true);

        private void SelectAllChecklistCb_Unchecked(object sender, RoutedEventArgs e) => SetAllChecklistChecked(false);

        private void SetAllChecklistChecked(bool isChecked)
        {
            if (_suppressSelectAllSync) return;
            _suppressSelectAllSync = true;
            try
            {
                foreach (var areaObj in ChecklistTree.Items)
                {
                    if (areaObj is System.Windows.Controls.TreeViewItem areaNode)
                    {
                        if (areaNode.Header is System.Windows.Controls.StackPanel areaPanel)
                        {
                            foreach (var child in areaPanel.Children)
                            {
                                if (child is System.Windows.Controls.CheckBox areaCb) areaCb.IsChecked = isChecked;
                            }
                        }
                        SetChildrenChecked(areaNode, isChecked);
                    }
                }
            }
            finally
            {
                _suppressSelectAllSync = false;
            }
        }

        private void ItemCb_SelectionChanged(object? sender, RoutedEventArgs e)
        {
            if (_suppressSelectAllSync) return;
            SyncSelectAllState();
        }

        private void SyncSelectAllState()
        {
            var total = 0;
            var selected = 0;
            foreach (var cb in EnumerateChecklistItemCheckBoxes())
            {
                total++;
                if (cb.IsChecked == true) selected++;
            }

            _suppressSelectAllSync = true;
            try
            {
                SelectAllChecklistCb.IsChecked = total > 0 && selected == total;
            }
            finally
            {
                _suppressSelectAllSync = false;
            }
        }

        private System.Collections.Generic.IEnumerable<System.Windows.Controls.CheckBox> EnumerateChecklistItemCheckBoxes()
        {
            foreach (var areaObj in ChecklistTree.Items)
            {
                if (areaObj is not System.Windows.Controls.TreeViewItem areaNode) continue;
                foreach (var catObj in areaNode.Items)
                {
                    if (catObj is not System.Windows.Controls.TreeViewItem catNode) continue;
                    foreach (var itemObj in catNode.Items)
                    {
                        if (itemObj is System.Windows.Controls.TreeViewItem itemTvi && itemTvi.Header is System.Windows.Controls.CheckBox cb)
                        {
                            yield return cb;
                        }
                    }
                }
            }
        }

        private void AreaCb_Unchecked(object? sender, RoutedEventArgs e)
        {
            if (sender is System.Windows.Controls.CheckBox cb && cb.Parent is System.Windows.Controls.StackPanel sp)
            {
                var tvi = FindAncestor<System.Windows.Controls.TreeViewItem>(sp);
                if (tvi != null)
                {
                    SetChildrenChecked(tvi, false);
                }
            }
        }

        private static T? FindAncestor<T>(DependencyObject? child) where T : DependencyObject
        {
            var parent = child;
            while (parent != null)
            {
                if (parent is T t) return t;
                parent = System.Windows.Media.VisualTreeHelper.GetParent(parent);
            }
            return null;
        }

        private void SetChildrenChecked(System.Windows.Controls.TreeViewItem root, bool isChecked)
        {
            foreach (var obj in root.Items)
            {
                if (obj is System.Windows.Controls.TreeViewItem tvi)
                {
                    if (tvi.Header is System.Windows.Controls.CheckBox cb) cb.IsChecked = isChecked;
                    SetChildrenChecked(tvi, isChecked);
                }
            }
        }

        private void UpdateStageIndicators()
        {
            try
            {
                // simple visual indicator: bold active stage
                Stage1Label.FontWeight = MainTabs.SelectedIndex == 0 ? FontWeights.Bold : FontWeights.Normal;
                Stage2Label.FontWeight = MainTabs.SelectedIndex == 1 ? FontWeights.Bold : FontWeights.Normal;
                Stage3Label.FontWeight = MainTabs.SelectedIndex == 2 ? FontWeights.Bold : FontWeights.Normal;
                Stage4Label.FontWeight = MainTabs.SelectedIndex == 3 ? FontWeights.Bold : FontWeights.Normal;
                ExitHeaderBtn.Visibility = MainTabs.SelectedIndex == 0 ? Visibility.Collapsed : Visibility.Visible;

                // Allow loading checklist at any time (user action required)
                LoadChecklistBtn.IsEnabled = true;
                StartEvalBtn.IsEnabled = _checklistLoaded && (_loadedItems != null && _loadedItems.Count > 0);
            }
            catch { }
        }

        private async Task PopulateChecklistStructureAsync()
        {
            try
            {
                if (_auditor == null) _auditor = new Auditor("");
                var groups = await _auditor.GetChecklistStructureAsync();
                this.Dispatcher.Invoke(() =>
                {
                    ChecklistTree.Items.Clear();
                    _loadedItems = new System.Collections.Generic.List<SQLAuditor.Lib.ChecklistItem>();
                    _loadedStructure = new System.Collections.Generic.List<(string, SQLAuditor.Lib.ChecklistItem)>();
                });

                // Build ChecklistTree as Area -> Category -> Item (checkboxes)
                this.Dispatcher.Invoke(() =>
                {
                    ChecklistTree.Items.Clear();
                    _loadedItems = new System.Collections.Generic.List<SQLAuditor.Lib.ChecklistItem>();
                    _loadedStructure = new System.Collections.Generic.List<(string, SQLAuditor.Lib.ChecklistItem)>();
                });

                foreach (var g in groups)
                {
                    foreach (var it in g.Items)
                    {
                        _loadedItems.Add(it);
                        _loadedStructure!.Add((g.Area, it));
                    }
                }

                this.Dispatcher.Invoke(() =>
                {
                    var byArea = _loadedStructure
                        .GroupBy(x => GetChecklistAreaId(x.Item.Id))
                        .OrderBy(a => a.Key, System.Collections.Generic.Comparer<string>.Create(CompareChecklistIds));

                    foreach (var areaGrp in byArea)
                    {
                        var areaTitle = areaGrp.FirstOrDefault().Area;
                        var areaHeader = new System.Windows.Controls.TreeViewItem();
                        var areaPanel = new System.Windows.Controls.StackPanel() { Orientation = System.Windows.Controls.Orientation.Horizontal };
                        var areaCb = new System.Windows.Controls.CheckBox() { Content = FormatAreaLabel(areaGrp.Key, areaTitle) };
                        areaCb.Tag = areaGrp.Key;
                        areaCb.Checked += AreaCb_Checked;
                        areaCb.Unchecked += AreaCb_Unchecked;
                        areaPanel.Children.Add(areaCb);
                        areaHeader.Header = areaPanel;
                        areaHeader.IsExpanded = true;

                        var bySubArea = areaGrp
                            .GroupBy(r => GetChecklistSubAreaId(r.Item.Id))
                            .OrderBy(c => c.Key, System.Collections.Generic.Comparer<string>.Create(CompareChecklistIds));

                        foreach (var subAreaGrp in bySubArea)
                        {
                            var subAreaTitle = subAreaGrp.FirstOrDefault().Item.Category;
                            var catNode = new System.Windows.Controls.TreeViewItem() { Header = FormatSubAreaLabel(subAreaGrp.Key, subAreaTitle), IsExpanded = true };
                            foreach (var pair in subAreaGrp.OrderBy(r => r.Item.Id, System.Collections.Generic.Comparer<string>.Create(CompareChecklistIds)))
                            {
                                var item = pair.Item;
                                var cb = new System.Windows.Controls.CheckBox() { Content = item.Id + " " + item.Description, Tag = item };
                                cb.Checked += ItemCb_SelectionChanged;
                                cb.Unchecked += ItemCb_SelectionChanged;
                                var node = new System.Windows.Controls.TreeViewItem() { Header = cb };
                                catNode.Items.Add(node);
                            }
                            areaHeader.Items.Add(catNode);
                        }
                        ChecklistTree.Items.Add(areaHeader);
                    }

                    SyncSelectAllState();
                });
            }
            catch (Exception ex)
            {
                Log("Populate checklist error: " + ex.Message);
            }
        }

        private void Log(string message)
        {
            try
            {
                // Only a started run has a directory to log into; nothing is written to results/ itself.
                // A fleet run logs to the batch folder, since a line rarely belongs to one server.
                var dir = _batchDirectory ?? AuditOutputPaths.ActiveRunDirectory;
                var line = $"{DateTime.UtcNow:O} {message}\n";
                if (dir != null)
                {
                    System.IO.Directory.CreateDirectory(dir);
                    var path = System.IO.Path.Combine(dir, "ui_log.txt");
                    System.IO.File.AppendAllText(path, line);
                }
                System.Diagnostics.Debug.WriteLine(message);
                try
                {
                    this.Dispatcher.Invoke(() =>
                    {
                        try
                        {
                            if (UiLogBox != null)
                            {
                                UiLogBox.AppendText(line);
                                UiLogBox.ScrollToEnd();
                            }
                        }
                        catch { }
                    });
                }
                catch { }
            }
            catch { }
        }

        private async void GenSummaryBtn_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                if (_isEvaluating)
                {
                    MessageBox.Show("Evaluation is still running. Wait for completion before generating the summary report.", "Evaluation in progress", MessageBoxButton.OK, MessageBoxImage.Warning);
                    return;
                }

                var incomplete = GetIncompleteEvaluationMessages();
                if (incomplete.Count > 0)
                {
                    var preview = string.Join("\n", incomplete.Take(12));
                    var more = incomplete.Count > 12 ? $"\n...and {incomplete.Count - 12} more item(s)." : string.Empty;
                    MessageBox.Show(
                        "Assessment is not complete. Finish these items before generating summary:\n\n"
                        + preview
                        + more,
                        "Incomplete Evaluation",
                        MessageBoxButton.OK,
                        MessageBoxImage.Warning);
                    return;
                }

                var path = UiFilePath("checklist_results.json");
                if (!System.IO.File.Exists(path)) { Log($"No checklist results found at {path}"); return; }
                var txt = System.IO.File.ReadAllText(path);
                var arr = JsonSerializer.Deserialize<SQLAuditor.Lib.ChecklistResult[]>(txt) ?? Array.Empty<SQLAuditor.Lib.ChecklistResult>();

                // Generate the summary report from the persisted checklist_results.json
                // using the shared report generator so the output stays consistent with
                // the report produced automatically at the end of an assessment.
                try
                {
                    RegenerateReportFromPersisted();
                    Log($"Rendered reports saved to {UiRunDirectory}");
                }
                catch (Exception ex) { Log("Failed to save report: " + ex.Message); }

                UpdateSummaryView(arr);
                SetTabIndex(3);
                UpdateStageIndicators();
            }
            catch (Exception ex)
            {
                Log("Generate summary error: " + ex.Message);
                MessageBox.Show("The summary could not be generated:\n\n" + ex.Message, "Generate Summary failed", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private void ExportManualAndGenerateBtn_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                if (_isEvaluating)
                {
                    MessageBox.Show("Evaluation is still running. Wait for completion so every manual check and its guidance can be exported.", "Evaluation in progress", MessageBoxButton.OK, MessageBoxImage.Warning);
                    return;
                }

                var resultsPath = UiFilePath("checklist_results.json");
                if (!System.IO.File.Exists(resultsPath))
                {
                    MessageBox.Show("No completed evaluation results were found. Run the evaluation first.", "No evaluation results", MessageBoxButton.OK, MessageBoxImage.Warning);
                    return;
                }

                var manualChecks = GetManualChecksForExport();
                if (manualChecks.Count == 0)
                {
                    MessageBox.Show("The current evaluation does not contain any manual checks to export.", "No manual checks", MessageBoxButton.OK, MessageBoxImage.Information);
                    return;
                }

                var pendingIds = GetUnresolvedManualCheckIds();
                var confirmation = MessageBox.Show(
                    $"Export {manualChecks.Count} manual check(s) to CSV and generate the reports?\n\n"
                    + $"{pendingIds.Count} unanswered manual check(s) will be marked Skipped and excluded from all scores. "
                    + "Submitted and previously copied manual decisions will be preserved.",
                    "Export manual checks and generate",
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Warning);
                if (confirmation != MessageBoxResult.Yes) return;

                var dialog = new SaveFileDialog
                {
                    Title = "Export Manual Checks",
                    FileName = ManualChecklistCsv.BuildExportFileName(DateTime.Now),
                    DefaultExt = ".csv",
                    Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*",
                    InitialDirectory = UiRunDirectory,
                    AddExtension = true,
                    OverwritePrompt = true,
                };
                if (dialog.ShowDialog(this) != true) return;

                ManualChecklistCsv.Write(dialog.FileName, manualChecks);
                var skippedCount = MarkPendingManualAsSkipped(pendingIds, dialog.FileName);
                RegenerateReportFromPersisted();

                var results = LoadPersistedResults() ?? Array.Empty<ChecklistResult>();
                UpdateSummaryView(results);
                SetTabIndex(3);
                UpdateStageIndicators();

                Log($"Exported {manualChecks.Count} manual check(s) to {dialog.FileName}; {skippedCount} unanswered check(s) were skipped.");
                MessageBox.Show(
                    $"Manual checks exported to:\n{dialog.FileName}\n\n"
                    + $"{skippedCount} unanswered manual check(s) were excluded from scoring. Reports were generated in:\n{UiRunDirectory}",
                    "Reports generated",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
            }
            catch (Exception ex)
            {
                Log("Manual CSV export failed: " + ex.Message);
                MessageBox.Show("The manual checks could not be exported or the reports could not be generated:\n\n" + ex.Message, "Export failed", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        }

        private async void ImportManualCsvBtn_Click(object sender, RoutedEventArgs e)
        {
            if (_isEvaluating)
            {
                MessageBox.Show("Evaluation is still running. Wait for completion before importing manual decisions.", "Evaluation in progress", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            if (_evalItemMap == null || _evalStatusMap == null
                || !System.IO.File.Exists(UiFilePath("checklist_results.json")))
            {
                MessageBox.Show("Start and complete the new evaluation before importing the filled CSV.", "No completed evaluation", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            var dialog = new OpenFileDialog
            {
                Title = "Import Filled Manual Checks",
                DefaultExt = ".csv",
                Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*",
                CheckFileExists = true,
                Multiselect = false,
            };
            if (dialog.ShowDialog(this) != true) return;

            ImportManualCsvBtn.IsEnabled = false;
            System.Windows.Input.Mouse.OverrideCursor = System.Windows.Input.Cursors.Wait;
            try
            {
                var importFile = ManualChecklistCsv.Read(dialog.FileName);
                try
                {
                    ManualChecklistCsv.StoreInRunDirectory(dialog.FileName, UiRunDirectory);
                }
                catch (Exception copyEx)
                {
                    Log("Could not store the imported manual CSV in the run folder: " + copyEx.Message);
                }
                var (applied, ignored) = await ApplyImportedManualChecksAsync(importFile.Rows);

                var issuePreview = string.Join("\n", importFile.Issues.Take(8));
                var moreIssues = importFile.Issues.Count > 8
                    ? $"\n...and {importFile.Issues.Count - 8} more row issue(s)."
                    : string.Empty;
                var details = string.IsNullOrWhiteSpace(issuePreview)
                    ? string.Empty
                    : "\n\nRows not imported:\n" + issuePreview + moreIssues;

                Log($"Imported {applied} manual decision(s) from {dialog.FileName}; ignored {ignored} row(s), {importFile.Issues.Count} row issue(s).");
                MessageBox.Show(
                    $"Imported {applied} manual decision(s).\n"
                    + $"Ignored {ignored} row(s) that are not selected manual checks in this run.\n"
                    + $"Rows needing correction: {importFile.Issues.Count}."
                    + details
                    + "\n\nWhen all required rows are resolved, click Generate Summary / Report.",
                    "Manual CSV imported",
                    MessageBoxButton.OK,
                    applied > 0 ? MessageBoxImage.Information : MessageBoxImage.Warning);
            }
            catch (Exception ex)
            {
                Log("Manual CSV import failed: " + ex.Message);
                MessageBox.Show("The manual CSV could not be imported:\n\n" + ex.Message, "Import failed", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            finally
            {
                System.Windows.Input.Mouse.OverrideCursor = null;
                ImportManualCsvBtn.IsEnabled = true;
            }
        }
    }
}

