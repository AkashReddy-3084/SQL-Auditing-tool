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

            // The enriched result for the submitted outcome+remarks, so re-persisting after
            // the engine's placeholder write never repeats the LLM call.
            public SQLAuditor.Lib.ChecklistResult? EnrichedResult { get; set; }
            public string? EnrichedKey { get; set; }
        }

        private sealed class ManualCheckExportRow
        {
            public string Id { get; init; } = string.Empty;
            public string Area { get; init; } = string.Empty;
            public string Description { get; init; } = string.Empty;
            public string Verification { get; init; } = string.Empty;
            public string ManualSteps { get; init; } = string.Empty;
            public string Status { get; init; } = string.Empty;
            public string Decision { get; init; } = string.Empty;
            public string Evidence { get; init; } = string.Empty;
        }

        private sealed class ManualCheckImportRow
        {
            public string Id { get; init; } = string.Empty;
            public string Decision { get; init; } = string.Empty;
            public string Evidence { get; init; } = string.Empty;
            public string ManualSteps { get; init; } = string.Empty;
        }

        private sealed class ManualCheckImportFile
        {
            public System.Collections.Generic.List<ManualCheckImportRow> Rows { get; } = new();
            public System.Collections.Generic.List<string> Issues { get; } = new();
        }

        private System.Threading.CancellationTokenSource? _progressWatcherCts;
        private long _progressStreamPos = 0;
        private bool _isVerified = false;
        private bool _isLlmVerified = false;
        private Auditor? _auditor;
        private System.Threading.CancellationTokenSource? _evaluationCts;
        private System.Threading.CancellationTokenSource? _scriptGenerationCts;
        private bool _isEvaluating = false;
        private bool _isGeneratingScripts = false;
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
        // Documentation/admin checks stay manual even when a script is mapped (mirrors Auditor.IsScriptMapped).
        private System.Collections.Generic.HashSet<string> _manualOnlyItemIds = new(StringComparer.OrdinalIgnoreCase);
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
        private int _sqlConnectionInputsVersion = 0;
        private bool _isVerifyingSql = false;

        public MainWindow()
        {
            InitializeComponent();
            // wire auth selection UI
            AuthMethodCombo.SelectionChanged += (s, e) =>
            {
                var sel = (AuthMethodCombo.SelectedItem as System.Windows.Controls.ComboBoxItem)?.Content?.ToString() ?? "Windows Authentication";
                if (sel == "SQL Login")
                {
                    SqlUserBox.Visibility = Visibility.Visible;
                    SqlPassBox.Visibility = Visibility.Visible;
                }
                else
                {
                    SqlUserBox.Visibility = Visibility.Collapsed;
                    SqlPassBox.Visibility = Visibility.Collapsed;
                }
                InvalidateSqlVerification();
            };
            FqdnText.TextChanged += (s, e) => InvalidateSqlVerification();
            SqlUserBox.TextChanged += (s, e) => InvalidateSqlVerification();
            SqlPassBox.PasswordChanged += (s, e) => InvalidateSqlVerification();
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
                                    // Keep Generate Scripts disabled while feature is inactive
                                    GenerateScriptsBtn.IsEnabled = false;
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
                _mcpFeasibleItemIds = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
                _manualOnlyItemIds = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
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
                                    if (isOperatorEvaluated) _manualOnlyItemIds.Add(prop.Name);

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
                catch { }

                // prepare maps
                _itemTypeMap = new System.Collections.Generic.Dictionary<string, string>();
                _itemScriptMap = new System.Collections.Generic.Dictionary<string, string[]>();

                // pre-fill Script entries from mapping file, but validate mapped files exist and are not autogenerated placeholders
                if (_loadedItems != null)
                {
                    foreach (var it in _loadedItems)
                    {
                        // Admin/documentation checks keep their script but are executed by the operator.
                        if (_manualOnlyItemIds.Contains(it.Id)) continue;

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
                GenerateScriptsBtn.IsEnabled = (_loadedItems != null && _loadedItems.Count > 0);
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

        private async void StartEvalBtn_Click(object sender, RoutedEventArgs e)
        {
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
                    () => _auditor!.RunChecklistAsync(progress, RequestUserInput, idsForRun, token, useHistorical, generateReports: true, targetDatabases: targetDatabases),
                    token);
                // The engine's final write persists manual items as "Evaluating" placeholders,
                // which can overwrite Pass/Fail decisions made while evaluation was still running.
                // Re-apply submitted manual outcomes, then refresh the report/summary from the merged file.
                await ReapplySubmittedManualResultsAsync();
                RegenerateReportFromPersisted();
                UpdateEvaluationProgressDisplay();
                Log($"Evaluation complete. {results.Length} items evaluated. Results in results/ folder.");
                UpdateSummaryView(LoadPersistedResults() ?? results);
                MessageBox.Show(this, "Evaluation completed successfully.", "Evaluation Complete", MessageBoxButton.OK, MessageBoxImage.Information);
                // checklist_results.json and the full final_report.md are produced
                // automatically by the Auditor at the end of the assessment.
                Log($"Summary report generated at {AuditOutputPaths.GetCurrentFilePath("final_report.md")}");
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
                var results = await _auditor!.RunChecklistAsync(progress, RequestUserInput, null, _evaluationCts.Token, useHistoricalManualResults: false, generateReports: true, targetDatabases: targetDatabases);
                UpdateEvaluationProgressDisplay();
                Log($"Completed evaluation of {results.Length} checklist items. Results in results/ folder.");
                UpdateSummaryView(results);
                MessageBox.Show(this, "Evaluation completed successfully.", "Evaluation Complete", MessageBoxButton.OK, MessageBoxImage.Information);
                // checklist_results.json and the full final_report.md are produced
                // automatically by the Auditor at the end of the assessment.
                Log($"Summary report generated at {AuditOutputPaths.GetCurrentFilePath("final_report.md")}");
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
                _evalStatusMap[item.Id] = (string.Equals(state.SelectedOutcome, "Pass", StringComparison.OrdinalIgnoreCase) ? "Passed" : "Failed", "AI-Manual");
            }

            UpdateManualActionButtonStates(state.SelectedOutcome, state.IsSubmitted);
            RenderEvaluationTree();
            Log($"Submitted manual evaluation for {item.Id} as {state.SelectedOutcome}.");
        }

        // Reads the leading Pass/Fail verdict from the reviewer's evidence text; falls back to an
        // unambiguous verdict word elsewhere in the text.
        private static string? ParseManualDecision(string? text)
        {
            if (string.IsNullOrWhiteSpace(text)) return null;

            var leading = System.Text.RegularExpressions.Regex.Match(
                text,
                @"^\s*(?<decision>pass(?:ed)?|fail(?:ed)?)\b",
                System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            if (leading.Success)
            {
                return leading.Groups["decision"].Value.StartsWith("p", StringComparison.OrdinalIgnoreCase) ? "Pass" : "Fail";
            }

            var hasPass = System.Text.RegularExpressions.Regex.IsMatch(
                text, @"\bpass(?:ed)?\b", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            var hasFail = System.Text.RegularExpressions.Regex.IsMatch(
                text, @"\bfail(?:ed|ure)?\b", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            if (hasPass ^ hasFail)
            {
                return hasPass ? "Pass" : "Fail";
            }

            return null;
        }

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
            ManualTitle.Text = $"Manual evaluation for {it.Id}";
            ManualStepsText.Text = ToPlainText(state.Instructions);
            _isHydratingManualUi = true;
            ManualOutputBox.Text = state.Remarks;
            _isHydratingManualUi = false;
            UpdateManualActionButtonStates(state.SelectedOutcome, state.IsSubmitted);
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
                var path = AuditOutputPaths.GetCurrentFilePath("checklist_results.json");
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

        private static void WriteManualChecksCsv(string path, System.Collections.Generic.IEnumerable<ManualCheckExportRow> rows)
        {
            var csv = new System.Text.StringBuilder();
            csv.AppendLine(string.Join(",", new[]
            {
                "Checklist ID", "Area", "Description", "Verification", "Manual Steps",
                "Current Status", "Decision", "Evidence",
            }.Select(ToCsvField)));

            foreach (var row in rows)
            {
                csv.AppendLine(string.Join(",", new[]
                {
                    row.Id, row.Area, row.Description, row.Verification, row.ManualSteps,
                    row.Status, row.Decision, row.Evidence,
                }.Select(ToCsvField)));
            }

            System.IO.File.WriteAllText(path, csv.ToString(), new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
        }

        private static string ToCsvField(string? value) =>
            $"\"{(value ?? string.Empty).Replace("\"", "\"\"")}\"";

        private static ManualCheckImportFile ReadManualChecksCsv(string path)
        {
            var result = new ManualCheckImportFile();
            using var parser = new Microsoft.VisualBasic.FileIO.TextFieldParser(path, System.Text.Encoding.UTF8)
            {
                TextFieldType = Microsoft.VisualBasic.FileIO.FieldType.Delimited,
                HasFieldsEnclosedInQuotes = true,
                TrimWhiteSpace = false,
            };
            parser.SetDelimiters(",");

            var headers = parser.ReadFields();
            if (headers == null || headers.Length == 0)
                throw new InvalidDataException("The CSV is empty or has no header row.");

            var headerIndexes = headers
                .Select((header, index) => new { Header = (header ?? string.Empty).Trim().TrimStart('\uFEFF'), Index = index })
                .GroupBy(entry => entry.Header, StringComparer.OrdinalIgnoreCase)
                .ToDictionary(group => group.Key, group => group.First().Index, StringComparer.OrdinalIgnoreCase);

            var requiredHeaders = new[] { "Checklist ID", "Decision", "Evidence" };
            var missingHeaders = requiredHeaders.Where(header => !headerIndexes.ContainsKey(header)).ToArray();
            if (missingHeaders.Length > 0)
                throw new InvalidDataException("Missing required CSV column(s): " + string.Join(", ", missingHeaders));

            var seenIds = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
            while (!parser.EndOfData)
            {
                var lineNumber = parser.LineNumber;
                string[]? fields;
                try
                {
                    fields = parser.ReadFields();
                }
                catch (Microsoft.VisualBasic.FileIO.MalformedLineException ex)
                {
                    result.Issues.Add($"Line {lineNumber}: malformed CSV ({ex.Message}).");
                    continue;
                }

                if (fields == null || fields.All(string.IsNullOrWhiteSpace)) continue;

                string Field(string header)
                {
                    if (!headerIndexes.TryGetValue(header, out var index) || index >= fields.Length) return string.Empty;
                    return fields[index]?.Trim() ?? string.Empty;
                }

                var id = Field("Checklist ID");
                if (string.IsNullOrWhiteSpace(id))
                {
                    result.Issues.Add($"Line {lineNumber}: Checklist ID is empty.");
                    continue;
                }

                if (!seenIds.Add(id))
                {
                    result.Issues.Add($"Line {lineNumber}: duplicate Checklist ID '{id}'.");
                    continue;
                }

                var decision = Field("Decision").ToLowerInvariant() switch
                {
                    "pass" or "passed" or "p" => "Pass",
                    "fail" or "failed" or "f" => "Fail",
                    "" => string.Empty,
                    _ => "Invalid",
                };
                if (decision.Length == 0)
                {
                    result.Issues.Add($"{id}: Decision is empty; enter Pass or Fail.");
                    continue;
                }
                if (decision == "Invalid")
                {
                    result.Issues.Add($"{id}: Decision must be Pass or Fail.");
                    continue;
                }

                var evidence = Field("Evidence");
                if (string.IsNullOrWhiteSpace(evidence))
                {
                    result.Issues.Add($"{id}: Evidence is empty.");
                    continue;
                }

                result.Rows.Add(new ManualCheckImportRow
                {
                    Id = id,
                    Decision = decision,
                    Evidence = evidence,
                    ManualSteps = Field("Manual Steps"),
                });
            }

            return result;
        }

        private async Task<(int Applied, int Ignored)> ApplyImportedManualChecksAsync(
            System.Collections.Generic.IEnumerable<ManualCheckImportRow> importedRows)
        {
            if (_evalItemMap == null || _evalStatusMap == null) return (0, importedRows.Count());

            var appliedIds = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var ignored = 0;
            foreach (var imported in importedRows)
            {
                if (!_evalItemMap.TryGetValue(imported.Id, out var pair)
                    || !_evalStatusMap.TryGetValue(imported.Id, out var statusEntry)
                    || !HistoricalManualResultsStore.IsManualTechnique(statusEntry.Technique)
                    || _copiedManualIds.Contains(imported.Id))
                {
                    ignored++;
                    continue;
                }

                var state = EnsureManualState(imported.Id);
                if (state.IsSubmitted)
                {
                    ignored++;
                    continue;
                }

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

            var path = AuditOutputPaths.GetCurrentFilePath("checklist_results.json");
            var exportedFileName = System.IO.Path.GetFileName(csvPath);
            var skippedCount = 0;

            lock (SQLAuditor.Lib.Auditor.ResultsFileLock)
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
                || string.Equals(status, "Complete", StringComparison.OrdinalIgnoreCase)
                || string.Equals(status, "Completed", StringComparison.OrdinalIgnoreCase)
                || string.Equals(status, "Error", StringComparison.OrdinalIgnoreCase);
        }

        private void UpdateEvaluationProgressDisplay()
        {
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
            if (_evalItemMap == null || _evalStatusMap == null) return;
            EvalTree.Items.Clear();
            var techniqueOrder = new[] { "Script", "AI-MCP", "AI-Manual" };

            foreach (var technique in techniqueOrder)
            {
                var techniqueItems = _evalItemMap
                    .Where(kv => _evalStatusMap.TryGetValue(kv.Key, out var state) && string.Equals(state.Technique, technique, StringComparison.OrdinalIgnoreCase))
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
                            var status = _evalStatusMap.TryGetValue(pair.Item.Id, out var st) ? st.Status : "Not Started";
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

                EvalTree.Items.Add(techniqueNode);
            }
        }

        private string EvaluateManualOutcome(string response)
        {
            if (string.IsNullOrWhiteSpace(response)) return "NeedsReview";
            if (string.Equals(response, "PASS", StringComparison.OrdinalIgnoreCase)) return "Pass";
            if (string.Equals(response, "FAIL", StringComparison.OrdinalIgnoreCase)) return "Fail";
            if (response.IndexOf("pass", StringComparison.OrdinalIgnoreCase) >= 0) return "Pass";
            if (response.IndexOf("fail", StringComparison.OrdinalIgnoreCase) >= 0) return "Fail";
            return "NeedsReview";
        }

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

                var status = string.Equals(outcome, "Pass", StringComparison.OrdinalIgnoreCase) ? "Passed" : "Failed";
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
            var outcome = string.Equals(state.SelectedOutcome, "Pass", StringComparison.OrdinalIgnoreCase) ? "Pass" : "Fail";
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
                    if (_auditor != null)
                    {
                        Log($"Reviewing manual evidence for {item.Id}...");
                        updated = await _auditor.BuildManualResultAsync(item, outcome, state.Instructions, state.Remarks);
                    }
                    else
                    {
                        var evidence = $"Manual Steps:\n{state.Instructions}\n\nOperator Remarks:\n{state.Remarks}\n\nSelected Outcome:\n{outcome}";
                        updated = SQLAuditor.Lib.ChecklistResultEnricher.Enrich(
                            new SQLAuditor.Lib.ChecklistResult(item.Id, item.Description, item.Verification, outcome, evidence, item.ScriptFile, "AI-Manual"));
                    }

                    state.EnrichedResult = updated;
                    state.EnrichedKey = key;
                }

                if (forceWrite || !_isEvaluating)
                    WriteManualResultToDisk(updated);
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

        private static void WriteManualResultToDisk(SQLAuditor.Lib.ChecklistResult updated)
        {
            var path = AuditOutputPaths.GetCurrentFilePath("checklist_results.json");
            // The engine writes this same file from its own thread at the end of a run.
            lock (SQLAuditor.Lib.Auditor.ResultsFileLock)
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
                    && (string.Equals(state.SelectedOutcome, "Pass", StringComparison.OrdinalIgnoreCase)
                     || string.Equals(state.SelectedOutcome, "Fail", StringComparison.OrdinalIgnoreCase)))
                {
                    await PersistManualResultAsync(item, state, forceWrite: true);
                }
            }
        }

        private System.Collections.Generic.IReadOnlyCollection<ChecklistResult>? LoadPersistedResults()
        {
            var path = AuditOutputPaths.GetCurrentFilePath("checklist_results.json");
            if (!System.IO.File.Exists(path)) return null;
            try
            {
                return JsonSerializer.Deserialize<System.Collections.Generic.List<ChecklistResult>>(System.IO.File.ReadAllText(path));
            }
            catch { return null; }
        }

        // Regenerates final_report.md and audit_report.xlsx from the current
        // checklist_results.json so both reports reflect re-applied manual decisions
        // instead of the engine's placeholder write. historical_last_run.json is refreshed
        // only when the reviewer explicitly asks for the report.
        private void RegenerateReportFromPersisted(bool refreshHistoricalManualResults = false)
        {
            try
            {
                var message = SQLAuditor.Lib.Auditor.GenerateReports(refreshHistoricalManualResults);
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

            var isEnabled = IsCurrentManualReadyForInput();
            SubmitBtn.IsEnabled = isEnabled;
            ManualOutputBox.IsEnabled = isEnabled;

            SubmitBtn.Opacity = isSubmitted ? 1.0 : 0.85;
            SubmitBtn.BorderThickness = isSubmitted ? new Thickness(3) : new Thickness(1);
            SubmitBtn.Content = isSubmitted ? "Submitted" : "Submit";
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
                    || string.Equals(status, "Failed", StringComparison.OrdinalIgnoreCase);

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

                    if (!string.Equals(manualState.SelectedOutcome, "Pass", StringComparison.OrdinalIgnoreCase)
                        && !string.Equals(manualState.SelectedOutcome, "Fail", StringComparison.OrdinalIgnoreCase))
                    {
                        messages.Add($"{item.Id}: enter Pass or Fail with the reason and submit.");
                        continue;
                    }

                    if (!manualState.IsSubmitted)
                    {
                        messages.Add($"{item.Id}: manual evaluation not submitted.");
                        continue;
                    }

                    if (!string.Equals(status, "Passed", StringComparison.OrdinalIgnoreCase)
                        && !string.Equals(status, "Failed", StringComparison.OrdinalIgnoreCase))
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
                var defaultPath = AuditOutputPaths.GetCurrentFilePath("final_report.md");
                if (!System.IO.File.Exists(defaultPath))
                {
                    MessageBox.Show($"No final report found at {defaultPath}. Run evaluation first.", "Export", MessageBoxButton.OK, MessageBoxImage.Warning);
                    return;
                }
                var dlg = new SaveFileDialog() { FileName = "final_report.md", Filter = "Markdown|*.md|All Files|*.*" };
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
            return _isEvaluating || _isGeneratingScripts;
        }

        private void ResetChecklistSessionStateForExit()
        {
            _checklistLoaded = false;
            _loadedItems = null;
            _loadedStructure = null;
            _itemTypeMap = null;
            _itemScriptMap = null;
            _mcpFeasibleItemIds.Clear();
            _manualOnlyItemIds.Clear();
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
            _scriptGenerationCts?.Cancel();
            _isGeneratingScripts = false;

            if (MainTabs.SelectedIndex == 1)
            {
                ResetChecklistSessionStateForExit();
            }

            var destination = MainTabs.SelectedIndex == 1 ? 0 : 1;
            SetTabIndex(destination);
            UpdateStageIndicators();
        }

        private void ExitHeaderBtn_Click(object sender, RoutedEventArgs e)
        {
            HandleExitNavigation();
        }

        private void ExitSummaryBtn_Click(object sender, RoutedEventArgs e)
        {
            HandleExitNavigation();
        }

        private async Task EnsureAuditor(string fqdn)
        {
            if (_auditor != null) return;

            // Build connection string according to auth selection
            string cs;
            try
            {
                var sel = (AuthMethodCombo.SelectedItem as System.Windows.Controls.ComboBoxItem)?.Content?.ToString() ?? "Windows Authentication";
                sel = sel.Trim();
                if (string.Equals(sel, "SQL Login", StringComparison.OrdinalIgnoreCase))
                {
                    var user = SqlUserBox.Text ?? "";
                    var pass = SqlPassBox.Password ?? "";
                    cs = $"Server={fqdn};Database=master;User Id={user};Password={pass};TrustServerCertificate=true;";
                }
                else
                {
                    // default to Windows Authentication
                    cs = $"Server={fqdn};Database=master;Integrated Security=true;TrustServerCertificate=true;";
                }
            }
            catch
            {
                cs = $"Server={fqdn};Integrated Security=true;TrustServerCertificate=true;";
            }
            _auditor = new Auditor(cs);
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
            AccessStatus.Text = "Testing connection...";
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

            // Make sure the LLM evaluators reflect the verified runtime configuration.
            _auditor?.EnsureLlmEvaluators();

            SetTabIndex(1);
            LoadChecklistBtn.IsEnabled = true;
            Log($"Proceeding to checklist with {targetDatabases.Length} database target(s).");
            try
            {
                await PopulateChecklistStructureAsync();
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
            }

            // Configuring a custom checklist runs guardrails, classification and script
            // generation through the LLM provider, so it also needs a verified provider.
            if (AddCustomChecklistItemBtn != null)
            {
                AddCustomChecklistItemBtn.IsEnabled = ready && _isLlmVerified;
            }
        }

        // Read-only row shown in the Custom Checklist card.
        private sealed class CustomChecklistCardItem
        {
            public string Id { get; init; } = "";
            public string Title { get; init; } = "";
            public string SubAreaLabel { get; init; } = "";
        }

        // Renders the custom items already present in custom-checklist.json, via the same
        // configuration store the rest of the feature uses. Informational only.
        private void RefreshCustomChecklistCard()
        {
            try
            {
                var items = SQLAuditor.Lib.ChecklistConfigurationStore.GetCatalog()
                    .Where(i => i.IsCustom)
                    .OrderBy(i => i.Id, System.Collections.Generic.Comparer<string>.Create(
                        SQLAuditor.Lib.ChecklistConfigurationStore.CompareIds))
                    .Select(i => new CustomChecklistCardItem
                    {
                        Id = i.Id,
                        Title = string.IsNullOrWhiteSpace(i.Title) ? i.Text : i.Title,
                        SubAreaLabel = string.IsNullOrWhiteSpace(i.SubAreaTitle)
                            ? i.SubAreaId
                            : $"{i.SubAreaId} · {i.SubAreaTitle}"
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

        // Opens the Add Configure Checklist page, then the Custom Checklist Progress page, and
        // finally lands on the existing Checklist page with default + custom items available.
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
                        : $"Custom checklist '{outcome.Title}' not added — {outcome.Status}: {outcome.Detail}");
                }
            }
            else
            {
                Log("Custom checklist configuration was cancelled.");
            }

            RefreshCustomChecklistCard();

            // Land on the Checklist page so both default and custom items can be selected.
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

        private async void GenerateScriptsBtn_Click(object sender, RoutedEventArgs e)
        {
            GenerateScriptsBtn.IsEnabled = false;
            _isGeneratingScripts = true;
            _scriptGenerationCts = new System.Threading.CancellationTokenSource();

            try
            {
                // Resolve the Backend base path (the ScriptGeneratorAgent expects it)
                var repoRoot = FindRepoRootFromCwd();
                if (repoRoot == null)
                {
                    MessageBox.Show(this, "Cannot locate the repository root (Backend/checklists not found).", "Generate Scripts", MessageBoxButton.OK, MessageBoxImage.Error);
                    return;
                }
                var basePath = System.IO.Path.Combine(repoRoot, "Backend");

                // Use the same LLM provider config as the rest of the app
                string llmBaseUrl, llmApiKey, llmModel;
                int llmTimeout;
                try
                {
                    llmBaseUrl = ProviderConfig.BaseUrl;
                    llmApiKey = ProviderConfig.ApiKey;
                    llmModel = ProviderConfig.Model;
                    llmTimeout = (int)ProviderConfig.Timeout.TotalSeconds;
                }
                catch (Exception exCfg)
                {
                    MessageBox.Show(this, $"LLM configuration error: {exCfg.Message}\n\nEnsure .env is configured.", "Generate Scripts", MessageBoxButton.OK, MessageBoxImage.Error);
                    return;
                }

                var promptsDir = System.IO.Path.Combine(basePath, "Modules", "generate_scripts", "prompts");
                if (!System.IO.Directory.Exists(promptsDir))
                {
                    MessageBox.Show(this, $"Prompts directory not found: {promptsDir}", "Generate Scripts", MessageBoxButton.OK, MessageBoxImage.Error);
                    return;
                }

                // Gather selected checklist items and convert to ScriptGenChecklistItem
                var selectedItems = new System.Collections.Generic.List<SQLAuditor.Agents.ScriptGenChecklistItem>();
                if (_loadedStructure != null && _selectedIds != null && _selectedIds.Count > 0)
                {
                    foreach (var id in _selectedIds)
                    {
                        var match = _loadedStructure.FirstOrDefault(x => x.Item.Id == id);
                        if (match.Item != null)
                        {
                            selectedItems.Add(new SQLAuditor.Agents.ScriptGenChecklistItem
                            {
                                ChecklistId = match.Item.Id,
                                Category = match.Item.Category ?? "",
                                CheckName = match.Item.Description,
                                Scope = "",
                                Description = match.Item.Description,
                                ExpectedOutcome = match.Item.Description
                            });
                        }
                    }
                }

                if (selectedItems.Count == 0)
                {
                    MessageBox.Show(this, "No checklist items selected. Please select items first.", "Generate Scripts", MessageBoxButton.OK, MessageBoxImage.Information);
                    return;
                }

                var confirm = MessageBox.Show(this,
                    $"Generate scripts for {selectedItems.Count} selected checklist item(s)?\n\nThis will call the configured LLM to create T-SQL/PowerShell audit scripts.",
                    "Generate Scripts", MessageBoxButton.YesNo, MessageBoxImage.Question);
                if (confirm != MessageBoxResult.Yes) return;

                Log($"Starting script generation for {selectedItems.Count} items...");

                var llmTimeoutCopy = llmTimeout;
                var llmBaseUrlCopy = llmBaseUrl;
                var llmApiKeyCopy = llmApiKey;
                var llmModelCopy = llmModel;
                var basePathCopy = basePath;

                var progressWindow = new ScriptGenerationProgressWindow(selectedItems.Count);
                progressWindow.Owner = this;

                progressWindow.RunGeneration(async (progress, ct) =>
                {
                    var processor = new SQLAuditor.Agents.ChecklistItemProcessor(
                        llmBaseUrlCopy, llmApiKeyCopy, llmModelCopy, promptsDir, llmTimeoutCopy, maxRetries: 3);
                    var validator = new SQLAuditor.Agents.ScriptOutputValidator();
                    var agent = new SQLAuditor.Agents.ScriptGeneratorAgent(processor, validator, basePathCopy);

                    return await agent.RunAsync(progress, selectedItems, ct);
                });

                progressWindow.ShowDialog();

                var result = progressWindow.Result;
                if (result != null)
                {
                    Log($"Script generation complete — Generated: {result.Generated.Count}, Skipped: {result.Skipped.Count}, Failed: {result.Failed.Count}");

                    if (result.Skipped.Count > 0)
                    {
                        var skippedMsg = string.Join("\n", result.Skipped.Select(s => $"  {s.ChecklistId}: {s.Reason}"));
                        Log($"Skipped items:\n{skippedMsg}");
                    }
                }
                else
                {
                    Log("Script generation was cancelled.");
                }
            }
            catch (Exception ex)
            {
                Log($"Script generation error: {ex.Message}");
                MessageBox.Show(this, $"Script generation failed:\n{ex.Message}", "Generate Scripts", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            finally
            {
                _isGeneratingScripts = false;
                _scriptGenerationCts?.Dispose();
                _scriptGenerationCts = null;
                GenerateScriptsBtn.IsEnabled = _checklistLoaded;
            }
        }

        private static string? FindRepoRootFromCwd()
        {
            var dir = new System.IO.DirectoryInfo(System.IO.Directory.GetCurrentDirectory());
            while (dir != null)
            {
                var candidate = System.IO.Path.Combine(dir.FullName, "Backend", "checklists", "master-checklist.json");
                if (System.IO.File.Exists(candidate)) return dir.FullName;
                var alt = System.IO.Path.Combine(dir.FullName, "Backend", "checklists", "master_checklist.json");
                if (System.IO.File.Exists(alt)) return dir.FullName;
                dir = dir.Parent;
            }
            return null;
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
                // Enable Generate Scripts when checklist is loaded and items are selected
                GenerateScriptsBtn.IsEnabled = _checklistLoaded && (_loadedItems != null && _loadedItems.Count > 0);
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
                var dir = AuditOutputPaths.ActiveRunDirectory ?? AuditOutputPaths.RootDirectory;
                System.IO.Directory.CreateDirectory(dir);
                var path = System.IO.Path.Combine(dir, "ui_log.txt");
                var line = $"{DateTime.UtcNow:O} {message}\n";
                System.IO.File.AppendAllText(path, line);
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

                var path = AuditOutputPaths.GetCurrentFilePath("checklist_results.json");
                if (!System.IO.File.Exists(path)) { Log($"No checklist results found at {path}"); return; }
                var txt = System.IO.File.ReadAllText(path);
                var arr = JsonSerializer.Deserialize<SQLAuditor.Lib.ChecklistResult[]>(txt) ?? Array.Empty<SQLAuditor.Lib.ChecklistResult>();

                // Generate the summary report from the persisted checklist_results.json
                // using the shared report generator so the output stays consistent with
                // the report produced automatically at the end of an assessment.
                try
                {
                    RegenerateReportFromPersisted(refreshHistoricalManualResults: true);
                    Log($"Rendered reports saved to {AuditOutputPaths.CurrentRunDirectory}");
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

                var resultsPath = AuditOutputPaths.GetCurrentFilePath("checklist_results.json");
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
                    FileName = $"manual_checks_{DateTime.Now:yyyyMMdd_HHmmss}.csv",
                    DefaultExt = ".csv",
                    Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*",
                    InitialDirectory = AuditOutputPaths.CurrentRunDirectory,
                    AddExtension = true,
                    OverwritePrompt = true,
                };
                if (dialog.ShowDialog(this) != true) return;

                WriteManualChecksCsv(dialog.FileName, manualChecks);
                var skippedCount = MarkPendingManualAsSkipped(pendingIds, dialog.FileName);
                RegenerateReportFromPersisted(refreshHistoricalManualResults: true);

                var results = LoadPersistedResults() ?? Array.Empty<ChecklistResult>();
                UpdateSummaryView(results);
                SetTabIndex(3);
                UpdateStageIndicators();

                Log($"Exported {manualChecks.Count} manual check(s) to {dialog.FileName}; {skippedCount} unanswered check(s) were skipped.");
                MessageBox.Show(
                    $"Manual checks exported to:\n{dialog.FileName}\n\n"
                    + $"{skippedCount} unanswered manual check(s) were excluded from scoring. Reports were generated in:\n{AuditOutputPaths.CurrentRunDirectory}",
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
                || !System.IO.File.Exists(AuditOutputPaths.GetCurrentFilePath("checklist_results.json")))
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
                var importFile = ReadManualChecksCsv(dialog.FileName);
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
                    + $"Ignored {ignored} row(s) that were not selected manual checks or were already completed.\n"
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

