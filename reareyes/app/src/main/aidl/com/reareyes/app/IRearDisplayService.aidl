package com.reareyes.app;

interface IRearDisplayService {
    void destroy() = 16777114;
    String showRearDisplay(int taskId) = 1;
String launchRearDisplay(boolean reuseVisibleTask) = 2;
}
