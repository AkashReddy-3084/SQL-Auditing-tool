using System.Windows;

namespace SQLAuditor.Wpf
{
    /// <summary>
    /// Modal readout of what the evidence indexer found. Keeps the manifest out of the login card,
    /// which has no room for it.
    /// </summary>
    public partial class EvidenceSummaryWindow : Window
    {
        public EvidenceSummaryWindow(string headline, string subhead, string detail)
        {
            InitializeComponent();
            HeadlineText.Text = headline;
            SubheadText.Text = subhead;
            DetailText.Text = detail;
        }

        private void OkButton_Click(object sender, RoutedEventArgs e) => Close();
    }
}
