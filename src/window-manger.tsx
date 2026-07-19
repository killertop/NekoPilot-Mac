import App from './App';
import { useTheme } from './hooks/useTheme';



export default function WindowManger() {
  // Apply the persisted appearance before rendering the main window.
  useTheme();
  return <App />;
}
