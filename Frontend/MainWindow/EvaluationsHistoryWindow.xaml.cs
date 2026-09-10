using System.Windows;

namespace SQLAuditor.Wpf
{
    public enum HistoryAction
    {
        None,
        Rerun,
        Edit
    }

    public partial class EvaluationsHistoryWindow : Window
    {
        public SQLAuditor.Lib.PreviousEvaluation? SelectedRun { get; private set; }
        public HistoryAction Action { get; private set; } = HistoryAction.None;

        public EvaluationsHistoryWindow()
        {
            InitializeComponent();

            var runs = SQLAuditor.Lib.PreviousEvaluationStore.FindRecentAcrossServers(5);
            HistoryList.ItemsSource = runs;
            EmptyText.Visibility = runs.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        private void Rerun_Click(object sender, RoutedEventArgs e) => Complete(sender, HistoryAction.Rerun);

        private void Edit_Click(object sender, RoutedEventArgs e) => Complete(sender, HistoryAction.Edit);

        private void Complete(object sender, HistoryAction action)
        {
            if ((sender as FrameworkElement)?.DataContext is not SQLAuditor.Lib.PreviousEvaluation run) return;
            SelectedRun = run;
            Action = action;
            DialogResult = true;
            Close();
        }

        private void Close_Click(object sender, RoutedEventArgs e)
        {
            DialogResult = false;
            Close();
        }
    }
}
