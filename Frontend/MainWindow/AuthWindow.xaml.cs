using System.Windows;

namespace SQLAuditor.Wpf
{
    public partial class AuthWindow : Window
    {
        public bool UseWindowsAuth => RbWindowsAuth.IsChecked == true;
        public string Username => UsernameBox.Text ?? string.Empty;
        public string Password => PasswordBox.Password ?? string.Empty;

        public AuthWindow()
        {
            InitializeComponent();
            UsernameBox.IsEnabled = false;
            PasswordBox.IsEnabled = false;
            RbWindowsAuth.Checked += (s, e) => { UsernameBox.IsEnabled = false; PasswordBox.IsEnabled = false; };
            RbSqlAuth.Checked += (s, e) => { UsernameBox.IsEnabled = true; PasswordBox.IsEnabled = true; };
        }

        private void Ok_Click(object sender, RoutedEventArgs e)
        {
            this.DialogResult = true;
            this.Close();
        }

        private void Cancel_Click(object sender, RoutedEventArgs e)
        {
            this.DialogResult = false;
            this.Close();
        }
    }
}

