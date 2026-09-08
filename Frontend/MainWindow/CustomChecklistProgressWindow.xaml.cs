using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using SQLAuditor.Lib;

namespace SQLAuditor.Wpf
{
    /// <summary>
    /// "Custom Checklist Progress" page. Drives <see cref="CustomChecklistPipeline"/> and owns the
    /// user verification gate: the generated script is shown here and nothing is written to
    /// custom-checklist.json / custom-deterministic-script-mapping.json until Approve is clicked.
    /// </summary>
    public partial class CustomChecklistProgressWindow : Window
    {
        private readonly IReadOnlyList<CustomChecklistRequest> _requests;
        private readonly CancellationTokenSource _cts = new();

        private TaskCompletionSource<bool>? _approvalGate;
        private bool _isComplete;
        private int _completedItems;

        public CustomChecklistRunResult? Result { get; private set; }

        public CustomChecklistProgressWindow(IReadOnlyList<CustomChecklistRequest> requests)
        {
            InitializeComponent();
            _requests = requests;
            Progress.Maximum = Math.Max(1, requests.Count);
            HeaderText.Text = $"Custom Checklist Progress - {requests.Count} item(s)";
        }

        public void Start()
        {
            var progress = new Progress<string>(Append);
            var outcomes = new Progress<CustomChecklistOutcome>(OnOutcome);

            _ = Task.Run(async () =>
            {
                try
                {
                    var pipeline = new CustomChecklistPipeline();
                    var result = await pipeline.RunAsync(_requests, progress, RequestApprovalAsync, _cts.Token, outcomes);
                    Dispatcher.BeginInvoke(new Action(() => OnComplete(result)));
                }
                catch (OperationCanceledException)
                {
                    Dispatcher.BeginInvoke(new Action(OnCancelled));
                }
                catch (Exception ex)
                {
                    Dispatcher.BeginInvoke(new Action(() => OnError(ex)));
                }
            });
        }

        // Called from the pipeline's worker thread; marshals the review to the UI and blocks the
        // pipeline (asynchronously) until the user answers. Cancellation completes the gate from
        // the Cancel button and from Window_Closing.
        private Task<bool> RequestApprovalAsync(PendingCustomChecklistItem pending, CancellationToken token)
        {
            var gate = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            _approvalGate = gate;

            Dispatcher.BeginInvoke(new Action(() => ShowForReview(pending)));
            return gate.Task;
        }

        private void ShowForReview(PendingCustomChecklistItem pending)
        {
            var (technique, why) = CustomChecklistSkill.DescribeEvaluationPath(pending);

            ReviewHeader.Text = pending.IsFeasible
                ? $"Generated script - {pending.Id}"
                : $"No script - {pending.Id}";

            ReviewSummary.Text =
                $"Area {pending.AreaId} / Sub-area {pending.SubAreaId} ({pending.SubAreaTitle})\n"
                + $"Title: {pending.Title}\n"
                + (pending.IsFeasible
                    ? $"Script type: {pending.ScriptType} | Scope: {pending.Scope}\nScoring: {pending.ScoringLogic}\n"
                    : $"No script is feasible for this item: {pending.Reason}\n")
                + $"Evaluated by: {technique} - {why}.";

            ScriptBox.Text = pending.IsFeasible
                ? pending.ScriptContent
                : $"(no script - this item will be evaluated by {technique})";

            ApproveBtn.IsEnabled = true;
            RejectBtn.IsEnabled = true;
        }

        private void ApproveBtn_Click(object sender, RoutedEventArgs e) => CompleteReview(true);

        private void RejectBtn_Click(object sender, RoutedEventArgs e) => CompleteReview(false);

        private void CompleteReview(bool approved)
        {
            ApproveBtn.IsEnabled = false;
            RejectBtn.IsEnabled = false;
            ReviewSummary.Text = approved ? "Approved - finalising..." : "Rejected - this item will not be added.";

            var gate = _approvalGate;
            _approvalGate = null;
            gate?.TrySetResult(approved);
        }

        private void OnOutcome(CustomChecklistOutcome outcome)
        {
            _completedItems++;
            Progress.Value = Math.Min(_completedItems, Progress.Maximum);
        }

        private void Append(string message)
        {
            LogBox.AppendText(message + Environment.NewLine);
            LogBox.ScrollToEnd();
            StageText.Text = message.Length > 160 ? message[..157] + "..." : message;
        }

        private void OnComplete(CustomChecklistRunResult result)
        {
            _isComplete = true;
            Result = result;

            Progress.Value = Progress.Maximum;
            ApproveBtn.IsEnabled = false;
            RejectBtn.IsEnabled = false;

            var added = result.Outcomes.Count(o => o.IsAdded);
            var rejected = result.Outcomes.Count(o => o.Status is "Rejected");
            var duplicates = result.Outcomes.Count(o => o.Status is "Duplicate");
            var other = result.Outcomes.Count - added - rejected - duplicates;

            HeaderText.Text = "Custom Checklist Configuration Complete";
            SummaryText.Text = $"Added: {added}   Guardrail rejections: {rejected}   Duplicates: {duplicates}   Not added: {other}";
            ReviewSummary.Text = "All items processed. The merged checklist and mapping have been regenerated.";

            ActionButton.Content = "Continue to Checklist";
        }

        private void OnCancelled()
        {
            _isComplete = true;
            Append("Cancelled. Nothing further was added.");
            ActionButton.Content = "Close";
        }

        private void OnError(Exception ex)
        {
            _isComplete = true;
            Append("ERROR: " + ex.Message);
            HeaderText.Text = "Custom Checklist Configuration Failed";
            ActionButton.Content = "Close";
        }

        private void ActionButton_Click(object sender, RoutedEventArgs e)
        {
            if (!_isComplete)
            {
                _cts.Cancel();
                _approvalGate?.TrySetResult(false);
                ActionButton.IsEnabled = false;
                Append("Cancelling after the current step...");
                return;
            }

            Close();
        }

        private void Window_Closing(object sender, System.ComponentModel.CancelEventArgs e)
        {
            if (!_isComplete)
            {
                var confirm = MessageBox.Show(this,
                    "Custom checklist processing is still running. Cancel it?",
                    "Custom Checklist Progress", MessageBoxButton.YesNo, MessageBoxImage.Question);
                if (confirm != MessageBoxResult.Yes)
                {
                    e.Cancel = true;
                    return;
                }

                _cts.Cancel();
                _approvalGate?.TrySetResult(false);
            }
        }
    }
}
