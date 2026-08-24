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
        private System.Collections.Generic.List<SQLAuditor.Lib.ChecklistItem>? _manualQueue;
        private int _manualIndex = -1;
        private System.Collections.Generic.Dictionary<string, string>? _manualInstructions;
        private System.Collections.Generic.Dictionary<string, ManualEvaluationState>? _manualStateMap;
        private System.Collections.Generic.Dictionary<string, (string Area, SQLAuditor.Lib.ChecklistItem Item)>? _evalItemMap;
        private System.Collections.Generic.Dictionary<string, (string Status, string Technique)>? _evalStatusMap;
        private bool _isHydratingManualUi = false;
        // Selected checklist IDs are kept in-memory for the current session only
        private System.Collections.Generic.List<string>? _selectedIds;

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
            };
            Log("Ready — enter SQL FQDN and click Verify Access.");
            // Start UI on Login tab (main window). Navigation via tab headers is disabled; use buttons to progress.
            MainTabs.SelectedIndex = 0;
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
                var path = System.IO.Path.Combine(System.IO.Directory.GetCurrentDirectory(), "results", "progress_stream.txt");
                while (true)
                {
                    if (token.IsCancellationRequested) return;
                    try
                    {
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

        private async void LoadChecklistBtn_Click(object sender, RoutedEventArgs e)
        {
            if (_auditor == null)
            {
                // Allow loading checklist without a verified DB connection for UI/testing convenience
                _auditor = new Auditor("");
                Log("No DB connection provided — using offline auditor for checklist load.");
            }
            Log("Loading checklist structure...");
            try
            {
                // Do not auto-generate placeholder scripts during checklist load; mapping should be authoritative.

                // Ensure checklist is loaded
                System.Collections.Generic.Dictionary<string, string[]?> mappingFile = new System.Collections.Generic.Dictionary<string, string[]?>();
                try
                {
                    var dir = new DirectoryInfo(Directory.GetCurrentDirectory());
                    string? root = null;
                    while (dir != null)
                    {
                        var candidate = Path.Combine(dir.FullName, "Backend", "checklist", "deterministic-script-mapping.json");
                        if (File.Exists(candidate))
                        {
                            root = dir.FullName;
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
                        if (mappingFile.TryGetValue(it.Id, out var files) && files != null && files.Length > 0)
                        {
                            var valid = new System.Collections.Generic.List<string>();
                            foreach (var f in files.Where(s => !string.IsNullOrWhiteSpace(s)))
                            {
                                try
                                {
                                    var candidate = f;
                                    if (!Path.IsPathRooted(candidate)) candidate = Path.Combine(Directory.GetCurrentDirectory(), candidate.Replace('/', Path.DirectorySeparatorChar));
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
                        type = _isVerified && _auditor != null ? "AI-MCP" : "AI-Manual";

                        // persist into maps
                        if (_itemTypeMap != null) _itemTypeMap[it.Id] = type;
                        if (_itemScriptMap != null) _itemScriptMap[it.Id] = scripts;
                    }

                    var area = _loadedStructure?.FirstOrDefault(x => x.Item.Id == it.Id).Area ?? string.Empty;
                    mappingRows.Add(new { Type = type, Area = area, Category = it.Category, Id = it.Id, Description = it.Description, Verification = it.Verification, ScriptFiles = string.Join(';', scripts) });
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
                    var normalized = mappingRows.Select(r => new { DisplayType = ((string)r.Type) == "Script" ? "Script" : "AI (MCP/Manual)", Area = (string)r.Area, Category = (string)r.Category, Id = (string)r.Id, Description = (string)r.Description, ScriptFiles = (string)r.ScriptFiles });
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

            var selectedLookup = new System.Collections.Generic.HashSet<string>(selected);
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
                    else if (_isVerified && _auditor != null)
                    {
                        initialTechnique = "AI-MCP";
                    }

                    _evalStatusMap[pair.Item.Id] = ("Not Started", initialTechnique);
                }
            }

            RenderEvaluationTree();
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

                            RenderEvaluationTree();
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
                        if (!_manualQueue.Any(m => m.Id == item.Id)) _manualQueue.Add(item);
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
                            RenderEvaluationTree();
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
                var results = await _auditor.RunChecklistAsync(progress, RequestUserInput, selected.Count == 0 ? null : selected, _evaluationCts.Token);
                // The engine's final write persists manual items as "Evaluating" placeholders,
                // which can overwrite Pass/Fail decisions made while evaluation was still running.
                // Re-apply submitted manual outcomes, then refresh the report/summary from the merged file.
                ReapplySubmittedManualResults();
                RegenerateReportFromPersisted();
                Log($"Evaluation complete. {results.Length} items evaluated. Results in results/ folder.");
                UpdateSummaryView(LoadPersistedResults() ?? results);
                // checklist_results.json and the full final_report.md are produced
                // automatically by the Auditor at the end of the assessment.
                Log("Summary report generated at results/final_report.md");
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
                var results = await _auditor!.RunChecklistAsync(progress, RequestUserInput, null, _evaluationCts.Token);
                Log($"Completed evaluation of {results.Length} checklist items. Results in results/ folder.");
                UpdateSummaryView(results);
                // checklist_results.json and the full final_report.md are produced
                // automatically by the Auditor at the end of the assessment.
                Log("Summary report generated at results/final_report.md");
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

        private void SubmitBtn_Click(object sender, RoutedEventArgs e)
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

            var inferred = EvaluateManualOutcome(state.Remarks);
            if (string.Equals(inferred, "Pass", StringComparison.OrdinalIgnoreCase)
                || string.Equals(inferred, "Fail", StringComparison.OrdinalIgnoreCase))
            {
                // On submit, prefer explicit outcome mentioned in remarks.
                state.SelectedOutcome = inferred;
            }
            else if (!string.Equals(state.SelectedOutcome, "Pass", StringComparison.OrdinalIgnoreCase)
                && !string.Equals(state.SelectedOutcome, "Fail", StringComparison.OrdinalIgnoreCase))
            {
                MessageBox.Show("Select Passed/Failed or include pass/fail in remarks before submitting.", "Manual Evaluation", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            state.IsSubmitted = true;
            PersistManualResult(item, state);

            if (_evalStatusMap != null)
            {
                _evalStatusMap[item.Id] = (string.Equals(state.SelectedOutcome, "Pass", StringComparison.OrdinalIgnoreCase) ? "Passed" : "Failed", "AI-Manual");
            }

            UpdateManualActionButtonStates(state.SelectedOutcome, state.IsSubmitted);
            RenderEvaluationTree();
            Log($"Submitted manual evaluation for {item.Id} as {state.SelectedOutcome}.");
        }

        private void MarkPassedBtn_Click(object sender, RoutedEventArgs e)
        {
            if (_pendingUserInput != null && !_pendingUserInput.Task.IsCompleted)
            {
                _pendingUserInput.TrySetResult("PASS");
                Log("Marked item as Passed (manual).");
                AdvanceManualIndex();
                return;
            }

            SaveCurrentManualDraft(false);
            SetManualOutcomeForCurrentItem("Pass", persistImmediately: true);
        }

        private void MarkFailedBtn_Click(object sender, RoutedEventArgs e)
        {
            if (_pendingUserInput != null && !_pendingUserInput.Task.IsCompleted)
            {
                _pendingUserInput.TrySetResult("FAIL");
                Log("Marked item as Failed (manual).");
                AdvanceManualIndex();
                return;
            }

            SaveCurrentManualDraft(false);
            SetManualOutcomeForCurrentItem("Fail", persistImmediately: true);
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
                var path = System.IO.Path.Combine(System.IO.Directory.GetCurrentDirectory(), "results", "checklist_results.json");
                if (!System.IO.File.Exists(path)) return Array.Empty<ChecklistResult>();
                var txt = System.IO.File.ReadAllText(path);
                return JsonSerializer.Deserialize<ChecklistResult[]>(txt) ?? Array.Empty<ChecklistResult>();
            }
            catch
            {
                return Array.Empty<ChecklistResult>();
            }
        }

        private void MarkPendingManualAsFailed()
        {
            var path = System.IO.Path.Combine(System.IO.Directory.GetCurrentDirectory(), "results", "checklist_results.json");
            var list = new System.Collections.Generic.List<SQLAuditor.Lib.ChecklistResult>();
            if (System.IO.File.Exists(path))
            {
                try { list = JsonSerializer.Deserialize<System.Collections.Generic.List<SQLAuditor.Lib.ChecklistResult>>(System.IO.File.ReadAllText(path)) ?? new System.Collections.Generic.List<SQLAuditor.Lib.ChecklistResult>(); } catch { list = new System.Collections.Generic.List<SQLAuditor.Lib.ChecklistResult>(); }
            }

            var pendingIds = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (_evalStatusMap != null)
            {
                foreach (var kv in _evalStatusMap)
                {
                    if (string.Equals(kv.Value.Technique, "AI-Manual", StringComparison.OrdinalIgnoreCase)
                        && (string.Equals(kv.Value.Status, "Pending Manual Evaluation", StringComparison.OrdinalIgnoreCase)
                            || string.Equals(kv.Value.Status, "Generating Manual Plan", StringComparison.OrdinalIgnoreCase)))
                    {
                        pendingIds.Add(kv.Key);
                    }
                }
            }

            if (_manualQueue != null)
            {
                foreach (var it in _manualQueue)
                {
                    pendingIds.Add(it.Id);
                }
            }

            foreach (var id in pendingIds)
            {
                if (_evalItemMap == null || !_evalItemMap.TryGetValue(id, out var pair)) continue;
                var item = pair.Item;
                var failEvidence = "Marked as Fail because manual evaluation was skipped by the operator.";
                var failResult = new SQLAuditor.Lib.ChecklistResult(item.Id, item.Description, item.Verification, "Fail", failEvidence, item.ScriptFile, "AI-Manual");
                failResult = SQLAuditor.Lib.ChecklistResultEnricher.Enrich(failResult);
                var idx = list.FindIndex(x => string.Equals(x.Id, item.Id, StringComparison.OrdinalIgnoreCase));
                if (idx >= 0) list[idx] = failResult;
                else list.Add(failResult);

                if (_evalStatusMap != null)
                {
                    _evalStatusMap[item.Id] = ("Failed", "AI-Manual");
                }
            }

            System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
            System.IO.File.WriteAllText(path, JsonSerializer.Serialize(list, new JsonSerializerOptions { WriteIndented = true }));

            if (_manualQueue != null) _manualQueue.Clear();
            _manualIndex = -1;
            ManualTitle.Text = "Manual steps";
            ManualStepsText.Text = string.Empty;
            ManualOutputBox.Text = string.Empty;
            RenderEvaluationTree();
        }

        private void UpdateSummaryView(System.Collections.Generic.IReadOnlyCollection<ChecklistResult> results)
        {
            var resultList = results?.ToList() ?? new System.Collections.Generic.List<ChecklistResult>();
            var total = resultList.Count;
            var passed = resultList.Count(r => string.Equals(r.Outcome, "Pass", StringComparison.OrdinalIgnoreCase));
            var failed = resultList.Count(r => string.Equals(r.Outcome, "Fail", StringComparison.OrdinalIgnoreCase));
            var review = resultList.Count(r => string.Equals(r.Outcome, "NeedsReview", StringComparison.OrdinalIgnoreCase));
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
                    new SummaryMetricItem { Label = "Needs Review", Value = review, Total = Math.Max(total, 1), Detail = "Items requiring follow-up", BarBrush = System.Windows.Media.Brushes.Goldenrod }
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
            if (string.Equals(status, "Not Started", StringComparison.OrdinalIgnoreCase)) return System.Windows.Media.Brushes.DimGray;
            if (string.Equals(status, "Not Applicable", StringComparison.OrdinalIgnoreCase)) return System.Windows.Media.Brushes.SlateGray;
            return System.Windows.Media.Brushes.IndianRed;
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

        private void ApplyDeferredManualDecision(string response)
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
                PersistManualResult(item, state);
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

        private void SetManualOutcomeForCurrentItem(string outcome, bool persistImmediately = false)
        {
            var item = GetCurrentManualItem();
            if (item == null)
            {
                Log("No pending manual checklist item selected.");
                return;
            }

            var state = EnsureManualState(item.Id);
            var changed = !string.Equals(state.SelectedOutcome, outcome, StringComparison.OrdinalIgnoreCase);
            state.SelectedOutcome = outcome;

            if (persistImmediately)
            {
                state.IsSubmitted = true;
                if (_evalStatusMap != null)
                {
                    _evalStatusMap[item.Id] = (string.Equals(outcome, "Pass", StringComparison.OrdinalIgnoreCase) ? "Passed" : "Failed", "AI-Manual");
                    RenderEvaluationTree();
                }
                PersistManualResult(item, state);
                UpdateManualActionButtonStates(state.SelectedOutcome, state.IsSubmitted);
                Log($"Marked {item.Id} as {outcome}.");
                return;
            }

            if (changed && state.IsSubmitted)
            {
                state.IsSubmitted = false;
                if (_evalStatusMap != null)
                {
                    _evalStatusMap[item.Id] = ("Pending Manual Evaluation", "AI-Manual");
                    RenderEvaluationTree();
                }
            }

            UpdateManualActionButtonStates(state.SelectedOutcome, state.IsSubmitted);
            Log($"Selected {outcome} for {item.Id}. Click Submit to save.");
        }

        private void PersistManualResult(SQLAuditor.Lib.ChecklistItem item, ManualEvaluationState state)
        {
            var path = System.IO.Path.Combine(System.IO.Directory.GetCurrentDirectory(), "results", "checklist_results.json");
            var list = new System.Collections.Generic.List<SQLAuditor.Lib.ChecklistResult>();
            if (System.IO.File.Exists(path))
            {
                try { list = JsonSerializer.Deserialize<System.Collections.Generic.List<SQLAuditor.Lib.ChecklistResult>>(System.IO.File.ReadAllText(path)) ?? new System.Collections.Generic.List<SQLAuditor.Lib.ChecklistResult>(); } catch { list = new System.Collections.Generic.List<SQLAuditor.Lib.ChecklistResult>(); }
            }

            var outcome = string.Equals(state.SelectedOutcome, "Pass", StringComparison.OrdinalIgnoreCase) ? "Pass" : "Fail";
            var evidence = $"Manual Steps:\n{state.Instructions}\n\nOperator Remarks:\n{state.Remarks}\n\nSelected Outcome:\n{outcome}";
            var updated = new SQLAuditor.Lib.ChecklistResult(item.Id, item.Description, item.Verification, outcome, evidence, item.ScriptFile, "AI-Manual")
            {
                McpUsage = null,
                McpExecutionTimeMs = null,
                McpEvidence = null
            };
            // Back-fill the report fields (Score, Severity, Finding, Recommendation, ...)
            // so manually evaluated items match the schema used by the report generator.
            updated = SQLAuditor.Lib.ChecklistResultEnricher.Enrich(updated);

            var idx = list.FindIndex(x => string.Equals(x.Id, item.Id, StringComparison.OrdinalIgnoreCase));
            if (idx >= 0) list[idx] = updated;
            else list.Add(updated);

            System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
            System.IO.File.WriteAllText(path, JsonSerializer.Serialize(list, new JsonSerializerOptions { WriteIndented = true }));
        }

        // Re-writes operator-submitted manual Pass/Fail decisions to checklist_results.json.
        // The engine persists manual items as "Evaluating" placeholders at the end of a run,
        // which can clobber decisions made while evaluation was still in progress.
        private void ReapplySubmittedManualResults()
        {
            if (_manualQueue == null || _manualStateMap == null) return;
            foreach (var item in _manualQueue)
            {
                if (_manualStateMap.TryGetValue(item.Id, out var state)
                    && state.IsSubmitted
                    && (string.Equals(state.SelectedOutcome, "Pass", StringComparison.OrdinalIgnoreCase)
                     || string.Equals(state.SelectedOutcome, "Fail", StringComparison.OrdinalIgnoreCase)))
                {
                    try { PersistManualResult(item, state); } catch { }
                }
            }
        }

        private System.Collections.Generic.IReadOnlyCollection<ChecklistResult>? LoadPersistedResults()
        {
            var path = System.IO.Path.Combine(System.IO.Directory.GetCurrentDirectory(), "results", "checklist_results.json");
            if (!System.IO.File.Exists(path)) return null;
            try
            {
                return JsonSerializer.Deserialize<System.Collections.Generic.List<ChecklistResult>>(System.IO.File.ReadAllText(path));
            }
            catch { return null; }
        }

        // Regenerates final_report.md from the current checklist_results.json so the report
        // reflects re-applied manual decisions instead of the engine's placeholder write.
        private void RegenerateReportFromPersisted()
        {
            try
            {
                var dir = System.IO.Path.Combine(System.IO.Directory.GetCurrentDirectory(), "results");
                var path = System.IO.Path.Combine(dir, "checklist_results.json");
                if (!System.IO.File.Exists(path)) return;
                var arr = JsonSerializer.Deserialize<ChecklistResult[]>(System.IO.File.ReadAllText(path)) ?? Array.Empty<ChecklistResult>();
                new SqlAuditor.Reporting.SummaryReportGenerator().GenerateFromFile(
                    path,
                    System.IO.Path.Combine(dir, "final_report.md"),
                    new SqlAuditor.Reporting.ReportMetadata
                    {
                        ReportDate = DateTime.UtcNow.ToString("yyyy-MM-dd"),
                        Auditors = "SQL Auditor Tool (automated)",
                        TotalChecklistItems = arr.Length,
                    });
            }
            catch { }
        }

        private void UpdateManualActionButtonStates(string? selectedOutcome, bool isSubmitted)
        {
            if (MarkPassedBtn == null || MarkFailedBtn == null || SubmitBtn == null || ManualOutputBox == null)
            {
                return;
            }

            var isEnabled = IsCurrentManualReadyForInput();
            MarkPassedBtn.IsEnabled = isEnabled;
            MarkFailedBtn.IsEnabled = isEnabled;
            SubmitBtn.IsEnabled = isEnabled;
            ManualOutputBox.IsEnabled = isEnabled;

            MarkPassedBtn.Opacity = string.Equals(selectedOutcome, "Pass", StringComparison.OrdinalIgnoreCase) ? 1.0 : 0.7;
            MarkPassedBtn.BorderThickness = string.Equals(selectedOutcome, "Pass", StringComparison.OrdinalIgnoreCase) ? new Thickness(3) : new Thickness(1);

            MarkFailedBtn.Opacity = string.Equals(selectedOutcome, "Fail", StringComparison.OrdinalIgnoreCase) ? 1.0 : 0.7;
            MarkFailedBtn.BorderThickness = string.Equals(selectedOutcome, "Fail", StringComparison.OrdinalIgnoreCase) ? new Thickness(3) : new Thickness(1);

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
                if (string.Equals(technique, "AI-Manual", StringComparison.OrdinalIgnoreCase))
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
                        messages.Add($"{item.Id}: choose Passed or Failed.");
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
                var defaultPath = System.IO.Path.Combine(System.IO.Directory.GetCurrentDirectory(), "results", "final_report.md");
                if (!System.IO.File.Exists(defaultPath))
                {
                    MessageBox.Show("No final report found in results/. Run evaluation first.", "Export", MessageBoxButton.OK, MessageBoxImage.Warning);
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

        private void ExitBtn_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                if (_isEvaluating)
                {
                    var choice = MessageBox.Show(
                        "An evaluation is still running. Exit anyway?",
                        "Exit SQL Auditor",
                        MessageBoxButton.YesNo,
                        MessageBoxImage.Warning);
                    if (choice != MessageBoxResult.Yes) return;

                    try { _evaluationCts?.Cancel(); } catch { }
                }

                try { _progressWatcherCts?.Cancel(); } catch { }
            }
            catch { }
            finally
            {
                Application.Current.Shutdown();
            }
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

        private async void VerifyBtn_Click(object sender, RoutedEventArgs e)
        {
            var fqdn = FqdnText.Text.Trim();
            if (string.IsNullOrEmpty(fqdn)) { AccessStatus.Text = "Enter FQDN first."; return; }
            AccessStatus.Text = "Testing connection...";
            VerifyBtn.IsEnabled = false;
            try
            {
                await EnsureAuditor(fqdn);
                var ok = await _auditor!.TestConnectionAsync();
                if (ok)
                {
                    _isVerified = true;
                    AccessStatus.Text = $"Verified: {fqdn}";
                    Log($"Connection to {fqdn} verified.");
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
            if (!_isVerified) return;

            // Make sure the LLM evaluators reflect the verified runtime configuration.
            _auditor?.EnsureLlmEvaluators();

            SetTabIndex(1);
            LoadChecklistBtn.IsEnabled = true;
            Log("Proceeding to checklist.");
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
            if (StartEvaluationBtn != null)
            {
                StartEvaluationBtn.IsEnabled = _isVerified;
            }
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

            try
            {
                // Resolve the Backend base path (the ScriptGeneratorAgent expects it)
                var repoRoot = FindRepoRootFromCwd();
                if (repoRoot == null)
                {
                    MessageBox.Show(this, "Cannot locate the repository root (Backend/checklist not found).", "Generate Scripts", MessageBoxButton.OK, MessageBoxImage.Error);
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

                var promptsDir = System.IO.Path.Combine(basePath, "agents", "prompts");
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
                GenerateScriptsBtn.IsEnabled = _checklistLoaded;
            }
        }

        private static string? FindRepoRootFromCwd()
        {
            var dir = new System.IO.DirectoryInfo(System.IO.Directory.GetCurrentDirectory());
            while (dir != null)
            {
                var candidate = System.IO.Path.Combine(dir.FullName, "Backend", "checklist", "master-checklist.json");
                if (System.IO.File.Exists(candidate)) return dir.FullName;
                var alt = System.IO.Path.Combine(dir.FullName, "Backend", "checklist", "master_checklist.json");
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
                var dir = System.IO.Path.Combine(System.IO.Directory.GetCurrentDirectory(), "results");
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

                var path = System.IO.Path.Combine(System.IO.Directory.GetCurrentDirectory(), "results", "checklist_results.json");
                if (!System.IO.File.Exists(path)) { Log("No results/checklist_results.json found"); return; }
                var txt = System.IO.File.ReadAllText(path);
                var arr = JsonSerializer.Deserialize<SQLAuditor.Lib.ChecklistResult[]>(txt) ?? Array.Empty<SQLAuditor.Lib.ChecklistResult>();

                // Generate the summary report from the persisted checklist_results.json
                // using the shared report generator so the output stays consistent with
                // the report produced automatically at the end of an assessment.
                try
                {
                    var outDir = System.IO.Path.Combine(System.IO.Directory.GetCurrentDirectory(), "results");
                    System.IO.Directory.CreateDirectory(outDir);
                    var outPath = System.IO.Path.Combine(outDir, "final_report.md");
                    new SqlAuditor.Reporting.SummaryReportGenerator().GenerateFromFile(
                        path,
                        outPath,
                        new SqlAuditor.Reporting.ReportMetadata
                        {
                            ReportDate = DateTime.UtcNow.ToString("yyyy-MM-dd"),
                            Auditors = "SQL Auditor Tool (automated)",
                            TotalChecklistItems = arr.Length,
                        });
                    Log("Rendered report saved to results/final_report.md");
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
    }
}

