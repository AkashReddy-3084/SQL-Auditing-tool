using System;
using System.Threading.Tasks;
using System.Windows;

namespace SQLAuditor.Wpf
{
    public partial class App : Application
    {
        protected override void OnStartup(StartupEventArgs e)
        {
            AppDomain.CurrentDomain.UnhandledException += CurrentDomain_UnhandledException;
            this.DispatcherUnhandledException += App_DispatcherUnhandledException;
            TaskScheduler.UnobservedTaskException += TaskScheduler_UnobservedTaskException;
            base.OnStartup(e);
        }

        private void App_DispatcherUnhandledException(object sender, System.Windows.Threading.DispatcherUnhandledExceptionEventArgs e)
        {
            LogException(e.Exception);
            e.Handled = true;
        }

        private void CurrentDomain_UnhandledException(object sender, UnhandledExceptionEventArgs e)
        {
            LogException(e.ExceptionObject as Exception);
        }

        private void TaskScheduler_UnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs e)
        {
            try
            {
                LogException(e.Exception);
                e.SetObserved();
            }
            catch { }
        }

        private void LogException(Exception? ex)
        {
            try
            {
                var dir = System.IO.Path.Combine(System.IO.Directory.GetCurrentDirectory(), "results");
                System.IO.Directory.CreateDirectory(dir);
                var path = System.IO.Path.Combine(dir, "startup_error.log");
                System.IO.File.WriteAllText(path, ex?.ToString() ?? "(null exception)");
                Console.Error.WriteLine(ex?.ToString() ?? "(null exception)");
            }
            catch { }
        }
    }
}

