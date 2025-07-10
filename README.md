# opti-input
A small application that does minor latency-focused tweaks to your keyboard and mouse.
It works by finding the USB Controller that your mouse and keyboard are on (if there is more than one), then enabling MSI Mode on it, giving it the highest priority, and setting it to have one core affinity.
This, of course, is at the cost of throughput. This should be a non-issue, though.
