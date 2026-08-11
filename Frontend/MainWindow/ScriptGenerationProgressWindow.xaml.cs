using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;

namespace SQLAuditor.Wpf
{
    public partial class ScriptGenerationProgressWindow : Window
    {
        private readonly CancellationTokenSource _cts = new();
        private bool _isComplete = false;
        private int _totalItems;
        private int _processedItems;
        private int _generated;
        private int _skipped;
        private int _failed;

        public CancellationToken CancellationToken => _cts.Token;

        public SQLAuditor.Agents.AgentRunResult? Result { get; private set; }

        public ScriptGenerationProgressWindow(int totalItems)
        {
            InitializeComponent();
            _totalItems = totalItems;
            ProgressBar.Maximum = totalItems;
            ProgressText.Text = $"0 / {totalItems}";
            CurrentItemText.Text = "Preparing...";
        }

        public void RunGeneration(Func<IProgress<string>, CancellationToken, Task<SQLAuditor.Agents.AgentRunResult>> work)
        {
            var progress = new Progress<string>(msg =>
            {
                Dispatcher.Invoke(() => HandleProgressMessage(msg));
            });

            _ = Task.Run(async () =>
            {
                try
                {
                    var result = await work(progress, _cts.Token);
                    Dispatcher.Invoke(() => OnComplete(result));
                }
                catch (OperationCanceledException)
                {
                    Dispatcher.Invoke(() => OnCancelled());
                }
                catch (Exception ex)
                {
                    Dispatcher.Invoke(() => OnError(ex));
                }
            });
        }

        private void HandleProgressMessage(string msg)
        {
            LogBox.AppendText(msg + "\n");
            LogBox.ScrollToEnd();

            // Detect item start: "[Agent] 1.2.3 - Check Name"
            if (msg.StartsWith("[Agent] ") && !msg.StartsWith("[Agent] Loaded"))
            {
                _processedItems++;
                UpdateProgress();

                var itemLabel = msg.Substring(8);
                if (itemLabel.Length > 80) itemLabel = itemLabel.Substring(0, 77) + "...";
                CurrentItemText.Text = itemLabel;
            }

            // Detect outcomes from step results
            if (msg.TrimStart().StartsWith("NOT FEASIBLE:", StringComparison.OrdinalIgnoreCase))
            {
                _skipped++;
                UpdateCounters();
            }
            else if (msg.TrimStart().StartsWith("VALIDATION FAILED:", StringComparison.OrdinalIgnoreCase)
                || msg.TrimStart().StartsWith("CONTENT VALIDATION FAILED:", StringComparison.OrdinalIgnoreCase)
                || msg.TrimStart().StartsWith("CORRECTED SCRIPT FORMAT INVALID:", StringComparison.OrdinalIgnoreCase)
                || msg.TrimStart().StartsWith("ERROR:", StringComparison.OrdinalIgnoreCase))
            {
                _failed++;
                UpdateCounters();
            }
            else if (msg.TrimStart().StartsWith("\u2713 Script saved:", StringComparison.Ordinal))
            {
                _generated++;
                UpdateCounters();
            }
        }

        private void UpdateProgress()
        {
            ProgressBar.Value = Math.Min(_processedItems, _totalItems);
            ProgressText.Text = $"{Math.Min(_processedItems, _totalItems)} / {_totalItems}";
        }

        private void UpdateCounters()
        {
            GeneratedCount.Text = _generated.ToString();
            SkippedCount.Text = _skipped.ToString();
            FailedCount.Text = _failed.ToString();
        }

        private void OnComplete(SQLAuditor.Agents.AgentRunResult result)
        {
            _isComplete = true;
            Result = result;

            // Use the authoritative final counts from the agent result
            GeneratedCount.Text = result.Generated.Count.ToString();
            SkippedCount.Text = result.Skipped.Count.ToString();
            FailedCount.Text = result.Failed.Count.ToString();

            ProgressBar.Value = _totalItems;
            ProgressText.Text = $"{_totalItems} / {_totalItems}";

            HeaderText.Text = "Script Generation Complete";
            CurrentItemText.Text = $"{result.Generated.Count} generated, {result.Skipped.Count} skipped, {result.Failed.Count} failed";

            ActionButton.Content = "Close";
            ActionButton.Background = new System.Windows.Media.SolidColorBrush(
                (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString("#FF0F4C81"));
            ActionButton.BorderBrush = ActionButton.Background;
        }

        private void OnCancelled()
        {
            _isComplete = true;
            HeaderText.Text = "Generation Cancelled";
            CurrentItemText.Text = "Cancelled by user.";
            ActionButton.Content = "Close";
            ActionButton.Background = new System.Windows.Media.SolidColorBrush(
                (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString("#FF0F4C81"));
            ActionButton.BorderBrush = ActionButton.Background;
        }

        private void OnError(Exception ex)
        {
            _isComplete = true;
            HeaderText.Text = "Generation Failed";
            CurrentItemText.Text = ex.Message;
            ActionButton.Content = "Close";
            ActionButton.Background = new System.Windows.Media.SolidColorBrush(
                (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString("#FF0F4C81"));
            ActionButton.BorderBrush = ActionButton.Background;
        }

        private void ActionButton_Click(object sender, RoutedEventArgs e)
        {
            if (_isComplete)
            {
                DialogResult = Result != null;
                Close();
            }
            else
            {
                _cts.Cancel();
                ActionButton.IsEnabled = false;
                ActionButton.Content = "Cancelling...";
                CurrentItemText.Text = "Cancelling — waiting for current item to finish...";
            }
        }

        private void Window_Closing(object sender, System.ComponentModel.CancelEventArgs e)
        {
            if (!_isComplete)
            {
                // Block close while running — force user to click Cancel
                e.Cancel = true;
            }
        }
    }
}
