using Toybox.Application;

class Tm3App extends Application.AppBase
{
	var mainView;

    function initialize()
    {
        AppBase.initialize();
    }

    // onStart() is called on application start up
    function onStart(state)
    {
    }

    // onStop() is called when your application is exiting
    function onStop(state)
    {
    }

    //! Return the initial view of your application here
    function getInitialView()
    {
        mainView = new Tm3View();
        mainView.setSelf(mainView);
        
        return [mainView];
	}
	
	// triggered by settings change in GCM
	function onSettingsChanged()
	{
    	mainView.onSettingsChanged();
	}
}